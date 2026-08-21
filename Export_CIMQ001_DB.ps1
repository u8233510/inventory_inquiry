param(
    [string]$ServerInstance = "",
    [string]$Database = "SAL_MRT",
    [string]$ProjectRoot = (Get-Location).Path,
    [System.Management.Automation.PSCredential]$SqlCredential
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

# ============================================================
# CIMQ001 DB Package Exporter v4
# Based on the working CXCR002 exporter approach:
# - Windows PowerShell + System.Data.SqlClient only
# - No Invoke-Sqlcmd
# - No SqlServer module
# - 300-second command timeout
# - Metadata-focused, no query-cache scan
# ============================================================

function Get-PlainPassword {
    param([System.Security.SecureString]$SecurePassword)

    $ptr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($SecurePassword)
    try {
        return [Runtime.InteropServices.Marshal]::PtrToStringBSTR($ptr)
    }
    finally {
        [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($ptr)
    }
}

function New-SqlConnection {
    param(
        [string]$Server,
        [string]$InitialCatalog,
        [System.Management.Automation.PSCredential]$Credential
    )

    $builder = New-Object System.Data.SqlClient.SqlConnectionStringBuilder
    $builder["Data Source"] = $Server
    $builder["Initial Catalog"] = $InitialCatalog
    $builder["Application Name"] = "CIMQ001_DB_Exporter"
    $builder["Connect Timeout"] = 30
    $builder["Encrypt"] = $false
    $builder["TrustServerCertificate"] = $true

    if ($Credential) {
        $builder["Integrated Security"] = $false
        $builder["User ID"] = $Credential.UserName
        $builder["Password"] = Get-PlainPassword $Credential.Password
    }
    else {
        $builder["Integrated Security"] = $true
    }

    return New-Object System.Data.SqlClient.SqlConnection($builder.ConnectionString)
}

function Invoke-SqlDataTable {
    param(
        [System.Data.SqlClient.SqlConnection]$Connection,
        [string]$Sql
    )

    $cmd = $Connection.CreateCommand()
    $cmd.CommandText = $Sql
    $cmd.CommandTimeout = 300

    $adapter = New-Object System.Data.SqlClient.SqlDataAdapter($cmd)
    $table = New-Object System.Data.DataTable

    try {
        [void]$adapter.Fill($table)
        return ,$table
    }
    finally {
        $adapter.Dispose()
        $cmd.Dispose()
    }
}

function Invoke-SqlScalar {
    param(
        [System.Data.SqlClient.SqlConnection]$Connection,
        [string]$Sql
    )

    $cmd = $Connection.CreateCommand()
    $cmd.CommandText = $Sql
    $cmd.CommandTimeout = 300

    try {
        return $cmd.ExecuteScalar()
    }
    finally {
        $cmd.Dispose()
    }
}

function Get-SafeFileName {
    param([string]$Name)
    foreach ($ch in [System.IO.Path]::GetInvalidFileNameChars()) {
        $Name = $Name.Replace($ch, "_")
    }
    return $Name
}

function Export-DataTableCsv {
    param(
        [System.Data.DataTable]$Table,
        [string]$Path
    )

    if ($Table.Rows.Count -eq 0) {
        [System.IO.File]::WriteAllText($Path, "", [System.Text.UTF8Encoding]::new($true))
        return
    }

    $rows = @()
    foreach ($row in $Table.Rows) {
        $obj = [ordered]@{}
        foreach ($col in $Table.Columns) {
            $value = $row[$col.ColumnName]
            if ($value -is [System.DBNull]) {
                $value = $null
            }
            $obj[$col.ColumnName] = $value
        }
        $rows += [PSCustomObject]$obj
    }

    $rows | Export-Csv -Path $Path -NoTypeInformation -Encoding UTF8
}

function Export-QueryCsv {
    param(
        [System.Data.SqlClient.SqlConnection]$Connection,
        [string]$Name,
        [string]$Sql,
        [string]$DocDir
    )

    Write-Host "  -> $Name" -ForegroundColor DarkCyan
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $dt = Invoke-SqlDataTable $Connection $Sql
    $sw.Stop()

    Export-DataTableCsv -Table $dt -Path (Join-Path $DocDir "$Name.csv")
    Write-Host "     rows=$($dt.Rows.Count), elapsed=$([math]::Round($sw.Elapsed.TotalSeconds,2)) sec" -ForegroundColor DarkGray
}

function Get-TableCreateScript {
    param(
        [System.Data.SqlClient.SqlConnection]$Connection,
        [int]$ObjectId,
        [string]$SchemaName,
        [string]$TableName
    )

    $columnsSql = @"
SELECT
    c.column_id,
    c.name AS ColumnName,
    t.name AS TypeName,
    c.max_length,
    c.precision,
    c.scale,
    c.is_nullable,
    c.is_identity,
    ic.seed_value,
    ic.increment_value,
    dc.name AS DefaultConstraintName,
    dc.definition AS DefaultDefinition,
    cc.definition AS ComputedDefinition,
    cc.is_persisted
FROM sys.columns AS c
JOIN sys.types AS t
    ON t.user_type_id = c.user_type_id
LEFT JOIN sys.identity_columns AS ic
    ON ic.object_id = c.object_id
   AND ic.column_id = c.column_id
LEFT JOIN sys.default_constraints AS dc
    ON dc.parent_object_id = c.object_id
   AND dc.parent_column_id = c.column_id
LEFT JOIN sys.computed_columns AS cc
    ON cc.object_id = c.object_id
   AND cc.column_id = c.column_id
WHERE c.object_id = $ObjectId
ORDER BY c.column_id;
"@

    $cols = Invoke-SqlDataTable $Connection $columnsSql
    $lines = New-Object System.Collections.Generic.List[string]

    foreach ($row in $cols.Rows) {
        $colName = [string]$row.ColumnName

        if (-not [string]::IsNullOrWhiteSpace([string]$row.ComputedDefinition)) {
            $persisted = if ([bool]$row.is_persisted) { " PERSISTED" } else { "" }
            $lines.Add("    [$colName] AS $($row.ComputedDefinition)$persisted")
            continue
        }

        $typeName = [string]$row.TypeName
        $typeSql = $typeName

        switch ($typeName.ToLowerInvariant()) {
            "varchar" {
                $len = if ([int]$row.max_length -eq -1) { "MAX" } else { [int]$row.max_length }
                $typeSql = "varchar($len)"
            }
            "char" {
                $typeSql = "char($([int]$row.max_length))"
            }
            "varbinary" {
                $len = if ([int]$row.max_length -eq -1) { "MAX" } else { [int]$row.max_length }
                $typeSql = "varbinary($len)"
            }
            "binary" {
                $typeSql = "binary($([int]$row.max_length))"
            }
            "nvarchar" {
                $len = if ([int]$row.max_length -eq -1) { "MAX" } else { [int]$row.max_length / 2 }
                $typeSql = "nvarchar($len)"
            }
            "nchar" {
                $typeSql = "nchar($([int]$row.max_length / 2))"
            }
            "decimal" {
                $typeSql = "decimal($($row.precision),$($row.scale))"
            }
            "numeric" {
                $typeSql = "numeric($($row.precision),$($row.scale))"
            }
            "datetime2" {
                $typeSql = "datetime2($($row.scale))"
            }
            "datetimeoffset" {
                $typeSql = "datetimeoffset($($row.scale))"
            }
            "time" {
                $typeSql = "time($($row.scale))"
            }
        }

        $identity = ""
        if ([bool]$row.is_identity) {
            $identity = " IDENTITY($($row.seed_value),$($row.increment_value))"
        }

        $nullable = if ([bool]$row.is_nullable) { " NULL" } else { " NOT NULL" }

        $default = ""
        if (-not [string]::IsNullOrWhiteSpace([string]$row.DefaultDefinition)) {
            $defaultName = [string]$row.DefaultConstraintName
            $default = " CONSTRAINT [$defaultName] DEFAULT $($row.DefaultDefinition)"
        }

        $lines.Add("    [$colName] $typeSql$identity$nullable$default")
    }

    $pkSql = @"
SELECT
    kc.name AS ConstraintName,
    i.type_desc AS IndexType,
    ic.key_ordinal,
    ic.is_descending_key,
    c.name AS ColumnName
FROM sys.key_constraints AS kc
JOIN sys.indexes AS i
    ON i.object_id = kc.parent_object_id
   AND i.index_id = kc.unique_index_id
JOIN sys.index_columns AS ic
    ON ic.object_id = i.object_id
   AND ic.index_id = i.index_id
JOIN sys.columns AS c
    ON c.object_id = ic.object_id
   AND c.column_id = ic.column_id
WHERE kc.parent_object_id = $ObjectId
  AND kc.type = 'PK'
ORDER BY ic.key_ordinal;
"@

    $pk = Invoke-SqlDataTable $Connection $pkSql
    if ($pk.Rows.Count -gt 0) {
        $pkName = [string]$pk.Rows[0].ConstraintName
        $indexType = if ([string]$pk.Rows[0].IndexType -eq "CLUSTERED") { "CLUSTERED" } else { "NONCLUSTERED" }

        $pkCols = @()
        foreach ($row in $pk.Rows) {
            $direction = if ([bool]$row.is_descending_key) { "DESC" } else { "ASC" }
            $pkCols += "[$($row.ColumnName)] $direction"
        }

        $lines.Add("    CONSTRAINT [$pkName] PRIMARY KEY $indexType (" + ($pkCols -join ", ") + ")")
    }

    $body = ($lines -join ",`r`n")
    $sb = New-Object System.Text.StringBuilder

    [void]$sb.AppendLine("USE [$($Connection.Database)];")
    [void]$sb.AppendLine("GO")
    [void]$sb.AppendLine("")
    [void]$sb.AppendLine("CREATE TABLE [$SchemaName].[$TableName]")
    [void]$sb.AppendLine("(")
    [void]$sb.AppendLine($body)
    [void]$sb.AppendLine(");")
    [void]$sb.AppendLine("GO")
    [void]$sb.AppendLine("")

    $indexesSql = @"
SELECT
    i.index_id,
    i.name,
    i.type_desc,
    i.is_unique,
    i.has_filter,
    i.filter_definition
FROM sys.indexes AS i
WHERE i.object_id = $ObjectId
  AND i.index_id > 0
  AND i.is_primary_key = 0
  AND i.is_hypothetical = 0
  AND i.name IS NOT NULL
ORDER BY i.index_id;
"@

    $indexes = Invoke-SqlDataTable $Connection $indexesSql

    foreach ($idx in $indexes.Rows) {
        $indexId = [int]$idx.index_id
        $indexColsSql = @"
SELECT
    ic.key_ordinal,
    ic.is_included_column,
    ic.is_descending_key,
    c.name AS ColumnName
FROM sys.index_columns AS ic
JOIN sys.columns AS c
    ON c.object_id = ic.object_id
   AND c.column_id = ic.column_id
WHERE ic.object_id = $ObjectId
  AND ic.index_id = $indexId
ORDER BY
    CASE WHEN ic.is_included_column = 0 THEN 0 ELSE 1 END,
    ic.key_ordinal,
    ic.index_column_id;
"@

        $idxCols = Invoke-SqlDataTable $Connection $indexColsSql
        $keys = @()
        $includes = @()

        foreach ($c in $idxCols.Rows) {
            if ([bool]$c.is_included_column) {
                $includes += "[$($c.ColumnName)]"
            }
            else {
                $direction = if ([bool]$c.is_descending_key) { "DESC" } else { "ASC" }
                $keys += "[$($c.ColumnName)] $direction"
            }
        }

        $unique = if ([bool]$idx.is_unique) { "UNIQUE " } else { "" }
        $cluster = if ([string]$idx.type_desc -eq "CLUSTERED") { "CLUSTERED" } else { "NONCLUSTERED" }

        $sql = "CREATE $unique$cluster INDEX [$($idx.name)] ON [$SchemaName].[$TableName] (" +
               ($keys -join ", ") + ")"

        if ($includes.Count -gt 0) {
            $sql += " INCLUDE (" + ($includes -join ", ") + ")"
        }

        if ([bool]$idx.has_filter -and
            -not [string]::IsNullOrWhiteSpace([string]$idx.filter_definition)) {
            $sql += " WHERE $($idx.filter_definition)"
        }

        [void]$sb.AppendLine($sql + ";")
        [void]$sb.AppendLine("GO")
    }

    return $sb.ToString()
}

# ------------------------------------------------------------
# Prompt / paths
# ------------------------------------------------------------
if ([string]::IsNullOrWhiteSpace($ServerInstance)) {
    $ServerInstance = Read-Host "SQL Server name or IP"
}

if (-not $SqlCredential) {
    $answer = Read-Host "Use SQL Login? (Y/N, N = Windows Authentication)"
    if ($answer -match '^[Yy]') {
        $sqlUser = Read-Host "SQL Login user"
        $sqlPassword = Read-Host "SQL Login password" -AsSecureString
        $SqlCredential = New-Object System.Management.Automation.PSCredential($sqlUser, $sqlPassword)
    }
}

$projectRootPath = [System.IO.Path]::GetFullPath($ProjectRoot)
$packageRoot = Join-Path $projectRootPath "database\cimq001"
$procDir = Join-Path $packageRoot "schema\procedures"
$viewDir = Join-Path $packageRoot "schema\views"
$tableDir = Join-Path $packageRoot "schema\tables"
$docDir = Join-Path $packageRoot "docs"

New-Item -ItemType Directory -Force -Path $procDir, $viewDir, $tableDir, $docDir | Out-Null

$conn = New-SqlConnection -Server $ServerInstance -InitialCatalog $Database -Credential $SqlCredential
$conn.Open()

try {
    Write-Host ""
    Write-Host "Connected: $ServerInstance / $Database" -ForegroundColor Cyan
    Write-Host "SQL connection test passed." -ForegroundColor DarkGreen

    # --------------------------------------------------------
    # 1. Procedures
    # --------------------------------------------------------
    Write-Host ""
    Write-Host "[1/10] Load stored procedures" -ForegroundColor Yellow

    $procedures = Invoke-SqlDataTable $conn @"
SELECT
    p.object_id,
    SchemaName = SCHEMA_NAME(p.schema_id),
    ObjectName = p.name,
    p.create_date,
    p.modify_date
FROM sys.procedures AS p
WHERE p.is_ms_shipped = 0
  AND p.name LIKE N'%InventoryInquiry%'
ORDER BY SchemaName, ObjectName;
"@

    Write-Host "Loaded procedures: $($procedures.Rows.Count)" -ForegroundColor DarkCyan

    # --------------------------------------------------------
    # 2. Views
    # --------------------------------------------------------
    Write-Host "[2/10] Load views" -ForegroundColor Yellow

    $views = Invoke-SqlDataTable $conn @"
SELECT
    v.object_id,
    SchemaName = SCHEMA_NAME(v.schema_id),
    ObjectName = v.name,
    v.create_date,
    v.modify_date
FROM sys.views AS v
WHERE v.is_ms_shipped = 0
  AND
  (
      v.name LIKE N'%InventoryInquiry%'
      OR v.name LIKE N'%InventoryDashboard%'
  )
ORDER BY SchemaName, ObjectName;
"@

    Write-Host "Loaded views: $($views.Rows.Count)" -ForegroundColor DarkCyan

    # --------------------------------------------------------
    # 3. Tables
    # --------------------------------------------------------
    Write-Host "[3/10] Load tables" -ForegroundColor Yellow

    $tables = Invoke-SqlDataTable $conn @"
SELECT
    t.object_id,
    SchemaName = SCHEMA_NAME(t.schema_id),
    ObjectName = t.name,
    t.create_date,
    t.modify_date
FROM sys.tables AS t
WHERE t.is_ms_shipped = 0
  AND t.name LIKE N'%InventoryInquiry%'
ORDER BY SchemaName, ObjectName;
"@

    Write-Host "Loaded tables: $($tables.Rows.Count)" -ForegroundColor DarkCyan

    # --------------------------------------------------------
    # 4. Dependencies
    # --------------------------------------------------------
    Write-Host "[4/10] Load dependencies" -ForegroundColor Yellow

    $allIds = @()
    foreach ($p in $procedures.Rows) { $allIds += [int]$p.object_id }
    foreach ($v in $views.Rows)      { $allIds += [int]$v.object_id }

    $idList = if ($allIds.Count -gt 0) { ($allIds -join ",") } else { "-1" }

    $dependencies = Invoke-SqlDataTable $conn @"
SELECT DISTINCT
    ReferencingObject =
        QUOTENAME(OBJECT_SCHEMA_NAME(d.referencing_id))
        + N'.'
        + QUOTENAME(OBJECT_NAME(d.referencing_id)),
    ReferencingType = ro.type_desc,
    ReferencedServer = d.referenced_server_name,
    ReferencedDatabase = ISNULL(d.referenced_database_name, DB_NAME()),
    ReferencedSchema = ISNULL(d.referenced_schema_name, OBJECT_SCHEMA_NAME(d.referenced_id)),
    ReferencedObject = ISNULL(d.referenced_entity_name, OBJECT_NAME(d.referenced_id)),
    ReferencedType = ref.type_desc
FROM sys.sql_expression_dependencies AS d
LEFT JOIN sys.objects AS ro
    ON ro.object_id = d.referencing_id
LEFT JOIN sys.objects AS ref
    ON ref.object_id = d.referenced_id
WHERE d.referencing_id IN ($idList)
ORDER BY
    ReferencingObject,
    ReferencedDatabase,
    ReferencedSchema,
    ReferencedObject;
"@

    Export-DataTableCsv -Table $dependencies -Path (Join-Path $docDir "DEPENDENCIES.csv")
    Write-Host "Loaded dependencies: $($dependencies.Rows.Count)" -ForegroundColor DarkCyan

    # --------------------------------------------------------
    # 5. Export definitions
    # --------------------------------------------------------
    Write-Host "[5/10] Export SP / VIEW / TABLE definitions" -ForegroundColor Yellow

    foreach ($p in $procedures.Rows) {
        $objectId = [int]$p.object_id
        $schema = [string]$p.SchemaName
        $name = [string]$p.ObjectName
        $definition = Invoke-SqlScalar $conn "SELECT OBJECT_DEFINITION($objectId);"

        if ($definition -ne $null -and -not [string]::IsNullOrWhiteSpace([string]$definition)) {
            $content = "USE [$Database];`r`nGO`r`n`r`n$definition`r`nGO`r`n"
            [System.IO.File]::WriteAllText(
                (Join-Path $procDir (Get-SafeFileName "$schema.$name.sql")),
                $content,
                [System.Text.UTF8Encoding]::new($true)
            )
        }
    }

    foreach ($v in $views.Rows) {
        $objectId = [int]$v.object_id
        $schema = [string]$v.SchemaName
        $name = [string]$v.ObjectName
        $definition = Invoke-SqlScalar $conn "SELECT OBJECT_DEFINITION($objectId);"

        if ($definition -ne $null -and -not [string]::IsNullOrWhiteSpace([string]$definition)) {
            $content = "USE [$Database];`r`nGO`r`n`r`n$definition`r`nGO`r`n"
            [System.IO.File]::WriteAllText(
                (Join-Path $viewDir (Get-SafeFileName "$schema.$name.sql")),
                $content,
                [System.Text.UTF8Encoding]::new($true)
            )
        }
    }

    foreach ($t in $tables.Rows) {
        $objectId = [int]$t.object_id
        $schema = [string]$t.SchemaName
        $name = [string]$t.ObjectName

        $script = Get-TableCreateScript `
            -Connection $conn `
            -ObjectId $objectId `
            -SchemaName $schema `
            -TableName $name

        [System.IO.File]::WriteAllText(
            (Join-Path $tableDir (Get-SafeFileName "$schema.$name.sql")),
            $script,
            [System.Text.UTF8Encoding]::new($true)
        )
    }

    # --------------------------------------------------------
    # 6. Core metadata
    # --------------------------------------------------------
    Write-Host "[6/10] Export indexes / table metadata" -ForegroundColor Yellow

    Export-QueryCsv $conn "INDEXES" @"
SELECT
    TableName = QUOTENAME(SCHEMA_NAME(t.schema_id)) + N'.' + QUOTENAME(t.name),
    i.index_id,
    i.name AS IndexName,
    i.type_desc AS IndexType,
    i.is_unique,
    i.is_primary_key,
    i.is_disabled,
    ic.key_ordinal,
    ic.is_included_column,
    ic.is_descending_key,
    c.name AS ColumnName
FROM sys.tables AS t
JOIN sys.indexes AS i
    ON i.object_id = t.object_id
JOIN sys.index_columns AS ic
    ON ic.object_id = i.object_id
   AND ic.index_id = i.index_id
JOIN sys.columns AS c
    ON c.object_id = ic.object_id
   AND c.column_id = ic.column_id
WHERE t.name LIKE N'%InventoryInquiry%'
  AND i.index_id > 0
ORDER BY t.name, i.index_id, ic.is_included_column, ic.key_ordinal, ic.index_column_id;
"@ $docDir

    # Fast metadata row counts, not COUNT_BIG table scans
    Export-QueryCsv $conn "TABLE_ROWCOUNTS" @"
SELECT
    TableName = QUOTENAME(SCHEMA_NAME(t.schema_id)) + N'.' + QUOTENAME(t.name),
    RecordCount = SUM(ps.row_count)
FROM sys.tables AS t
JOIN sys.dm_db_partition_stats AS ps
    ON ps.object_id = t.object_id
   AND ps.index_id IN (0,1)
WHERE t.name LIKE N'%InventoryInquiry%'
GROUP BY t.schema_id, t.name
ORDER BY t.name;
"@ $docDir

    # --------------------------------------------------------
    # 7. Activity evidence
    # --------------------------------------------------------
    Write-Host "[7/10] Export Activity evidence" -ForegroundColor Yellow

    Export-QueryCsv $conn "ACTIVITY_SUMMARY" @"
SELECT
    ActivityType,
    COUNT_BIG(*) AS RecordCount,
    MIN(ActivityDate) AS MinActivityDate,
    MAX(ActivityDate) AS MaxActivityDate
FROM dbo.InventoryInquiryActivity
GROUP BY ActivityType
ORDER BY ActivityType;
"@ $docDir

    Export-QueryCsv $conn "ACTIVITY_LOAD_STATE" @"
SELECT
    ProcessName,
    BackfillBeforeDate,
    OracleMinDate,
    BackfillComplete,
    LastSourceRows,
    LastInsertedRows,
    LastSuccessfulAt
FROM dbo.InventoryInquiryActivityLoadState
ORDER BY ProcessName;
"@ $docDir

    Export-QueryCsv $conn "ACTIVITY_REFERENCES" @"
SELECT
    ObjectName =
        QUOTENAME(OBJECT_SCHEMA_NAME(o.object_id))
        + N'.'
        + QUOTENAME(o.name),
    o.type_desc AS ObjectType,
    UsesActivity =
        CASE WHEN m.definition LIKE N'%InventoryInquiryActivity%' THEN 1 ELSE 0 END,
    UsesLoadState =
        CASE WHEN m.definition LIKE N'%InventoryInquiryActivityLoadState%' THEN 1 ELSE 0 END,
    UsesLegacyTLFSWork =
        CASE WHEN m.definition LIKE N'%InventoryInquiryActivity_TLFS_Work%' THEN 1 ELSE 0 END
FROM sys.objects AS o
JOIN sys.sql_modules AS m
    ON m.object_id = o.object_id
WHERE
       m.definition LIKE N'%InventoryInquiryActivity%'
    OR m.definition LIKE N'%InventoryInquiryActivityLoadState%'
    OR m.definition LIKE N'%InventoryInquiryActivity_TLFS_Work%'
ORDER BY ObjectName;
"@ $docDir

    # --------------------------------------------------------
    # 8. Snapshot status
    # --------------------------------------------------------
    Write-Host "[8/10] Export Snapshot status" -ForegroundColor Yellow

    Export-QueryCsv $conn "SNAPSHOT_TYPE_DISTRIBUTION" @"
SELECT
    ta_ima01 AS InventoryType,
    COUNT_BIG(*) AS RecordCount,
    MIN(SnapshotTime) AS MinSnapshotTime,
    MAX(SnapshotTime) AS MaxSnapshotTime
FROM dbo.InventoryInquirySnapshot
GROUP BY ta_ima01
ORDER BY ta_ima01;
"@ $docDir

    Export-QueryCsv $conn "WORK_TYPE_DISTRIBUTION" @"
SELECT
    ta_ima01 AS InventoryType,
    COUNT_BIG(*) AS RecordCount,
    MIN(SnapshotTime) AS MinSnapshotTime,
    MAX(SnapshotTime) AS MaxSnapshotTime
FROM dbo.InventoryInquirySnapshot_Work
GROUP BY ta_ima01
ORDER BY ta_ima01;
"@ $docDir

    # --------------------------------------------------------
    # 9. SQL Agent
    # --------------------------------------------------------
    Write-Host "[9/10] Export SQL Agent job / schedule" -ForegroundColor Yellow

    $msdb = New-SqlConnection -Server $ServerInstance -InitialCatalog "msdb" -Credential $SqlCredential
    $msdb.Open()

    try {
        Export-QueryCsv $msdb "SQL_AGENT_JOB_STEPS" @"
SELECT
    j.name AS JobName,
    j.enabled AS JobEnabled,
    s.step_id AS StepId,
    s.step_name AS StepName,
    s.database_name AS DatabaseName,
    s.subsystem AS Subsystem,
    s.command AS Command
FROM dbo.sysjobs AS j
JOIN dbo.sysjobsteps AS s
    ON s.job_id = j.job_id
WHERE
       s.command LIKE N'%InventoryInquiry%'
    OR j.name LIKE N'%庫存%'
ORDER BY j.name, s.step_id;
"@ $docDir

        Export-QueryCsv $msdb "SQL_AGENT_SCHEDULES" @"
SELECT
    j.name AS JobName,
    sch.name AS ScheduleName,
    sch.enabled AS ScheduleEnabled,
    sch.freq_type AS FreqType,
    sch.freq_interval AS FreqInterval,
    sch.freq_subday_type AS FreqSubdayType,
    sch.freq_subday_interval AS FreqSubdayInterval,
    sch.active_start_date AS ActiveStartDate,
    sch.active_start_time AS ActiveStartTime
FROM dbo.sysjobs AS j
JOIN dbo.sysjobschedules AS js
    ON js.job_id = j.job_id
JOIN dbo.sysschedules AS sch
    ON sch.schedule_id = js.schedule_id
WHERE
       j.name LIKE N'%庫存%'
    OR EXISTS
      (
          SELECT 1
          FROM dbo.sysjobsteps AS s
          WHERE s.job_id = j.job_id
            AND s.command LIKE N'%InventoryInquiry%'
      )
ORDER BY j.name, sch.name;
"@ $docDir
    }
    finally {
        if ($msdb.State -ne [System.Data.ConnectionState]::Closed) {
            $msdb.Close()
        }
        $msdb.Dispose()
    }

    # --------------------------------------------------------
    # 10. Object index / manifest
    # --------------------------------------------------------
    Write-Host "[10/10] Write object index / manifest" -ForegroundColor Yellow

    $index = New-Object System.Collections.Generic.List[string]
    $index.Add("# CIMQ001 Database Object Index")
    $index.Add("")
    $index.Add("Generated: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')")
    $index.Add("")
    $index.Add("Server: $ServerInstance")
    $index.Add("Database: $Database")
    $index.Add("")
    $index.Add("## Stored Procedures")
    $index.Add("")
    foreach ($p in $procedures.Rows) {
        $index.Add("- $($p.SchemaName).$($p.ObjectName)")
    }
    $index.Add("")
    $index.Add("## Views")
    $index.Add("")
    foreach ($v in $views.Rows) {
        $index.Add("- $($v.SchemaName).$($v.ObjectName)")
    }
    $index.Add("")
    $index.Add("## Tables")
    $index.Add("")
    foreach ($t in $tables.Rows) {
        $index.Add("- $($t.SchemaName).$($t.ObjectName)")
    }

    [System.IO.File]::WriteAllLines(
        (Join-Path $docDir "OBJECT_INDEX.md"),
        $index,
        [System.Text.UTF8Encoding]::new($true)
    )

    $manifest = [ordered]@{
        generated_at = (Get-Date -Format "yyyy-MM-ddTHH:mm:ss")
        server = $ServerInstance
        database = $Database
        procedure_count = $procedures.Rows.Count
        view_count = $views.Rows.Count
        table_count = $tables.Rows.Count
    }

    $manifest |
        ConvertTo-Json -Depth 5 |
        Set-Content -Path (Join-Path $packageRoot "manifest.json") -Encoding UTF8

    Write-Host ""
    Write-Host "CIMQ001 DB package exported successfully." -ForegroundColor Green
    Write-Host "Output:     $packageRoot"
    Write-Host "Procedures: $($procedures.Rows.Count)"
    Write-Host "Views:      $($views.Rows.Count)"
    Write-Host "Tables:     $($tables.Rows.Count)"
    Write-Host ""
    Write-Host "Please zip database\cimq001 and upload it."
}
finally {
    if ($conn.State -ne [System.Data.ConnectionState]::Closed) {
        $conn.Close()
    }
    $conn.Dispose()
}
