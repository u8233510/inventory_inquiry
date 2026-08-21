USE [SAL_MRT];
GO


CREATE   PROCEDURE dbo.sp_Load_InventoryInquiryActivity_M302
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE
          @ProcessName        SYSNAME = N'InventoryInquiryActivity_TLFS_M302'
        , @Today              DATE = CONVERT(DATE, GETDATE())
        , @RecentFromDate     DATE
        , @RecentToDate       DATE
        , @BackfillFromDate   DATE = NULL
        , @BackfillToDate     DATE = NULL
        , @BackfillBeforeDate DATE
        , @OracleMinDate      DATE
        , @OracleMinMonth     DATE
        , @BackfillComplete   BIT
        , @DoBackfill         BIT = 0
        , @SourceRows         BIGINT = 0
        , @InsertedRows       BIGINT = 0
        , @LoadBatchId        UNIQUEIDENTIFIER = NEWID()
        , @LoadedAt           DATETIME2(0) = SYSDATETIME()
        , @OracleSql          NVARCHAR(MAX)
        , @Command            NVARCHAR(MAX)
        , @RecentFromText     CHAR(10)
        , @RecentToText       CHAR(10)
        , @BackfillFromText   CHAR(10)
        , @BackfillToText     CHAR(10)
        , @Quote              NCHAR(1) = NCHAR(39)
        , @LockResult         INT;


    /*============================================================
      1. 防止 M302 Activity 同時重複執行
    ============================================================*/
    EXEC @LockResult = sys.sp_getapplock
          @Resource = N'SAL_MRT.InventoryInquiryActivity.TLFS.M302'
        , @LockMode = N'Exclusive'
        , @LockOwner = N'Session'
        , @LockTimeout = 0;

    IF @LockResult < 0
    BEGIN
        THROW 50401,
              N'M302 Activity 同步程序目前已經在執行中。',
              1;
    END;


    BEGIN TRY

        /*========================================================
          2. 必須先有 M302 Snapshot
        ========================================================*/
        IF NOT EXISTS
        (
            SELECT 1
            FROM dbo.InventoryInquirySnapshot
            WHERE OperatingCenter = N'M302'
        )
        BEGIN
            THROW 50402,
                  N'M302 Snapshot 尚無資料，請先執行 sp_Load_InventoryInquirySnapshot_Core_M302。',
                  1;
        END;


        IF COL_LENGTH
        (
            N'dbo.InventoryInquiryActivity',
            N'OperatingCenter'
        ) IS NULL
        BEGIN
            THROW 50403,
                  N'InventoryInquiryActivity 缺少 OperatingCenter 欄位。',
                  1;
        END;


        /*========================================================
          3. 最近 7 天每次重新同步
        ========================================================*/
        SET @RecentFromDate = DATEADD(DAY, -7, @Today);
        SET @RecentToDate   = DATEADD(DAY,  1, @Today);


        /*========================================================
          4. 第一次執行：
             取得 M302 Oracle TLFS 最早日期
        ========================================================*/
        IF NOT EXISTS
        (
            SELECT 1
            FROM dbo.InventoryInquiryActivityLoadState
            WHERE ProcessName = @ProcessName
        )
        BEGIN

            SELECT
                @OracleMinDate = TRY_CONVERT(DATE, MIN_TLFS12)
            FROM OPENQUERY
            (
                [ORACLE_LINKED_SERVER],
                '
                    SELECT
                        TRUNC(MIN(tlfs12)) AS MIN_TLFS12
                    FROM M302_2023.tlfs_file
                    WHERE tlfs12 IS NOT NULL
                '
            );

            INSERT INTO dbo.InventoryInquiryActivityLoadState
            (
                  ProcessName
                , BackfillBeforeDate
                , OracleMinDate
                , BackfillComplete
            )
            VALUES
            (
                  @ProcessName
                , DATEADD
                  (
                      MONTH,
                      1,
                      DATEFROMPARTS
                      (
                          YEAR(@Today),
                          MONTH(@Today),
                          1
                      )
                  )
                , @OracleMinDate
                , CASE
                      WHEN @OracleMinDate IS NULL THEN 1
                      ELSE 0
                  END
            );
        END;


        SELECT
              @BackfillBeforeDate = BackfillBeforeDate
            , @OracleMinDate      = OracleMinDate
            , @BackfillComplete   = BackfillComplete
        FROM dbo.InventoryInquiryActivityLoadState
        WHERE ProcessName = @ProcessName;


        IF @OracleMinDate IS NOT NULL
        BEGIN
            SET @OracleMinMonth =
                DATEFROMPARTS
                (
                    YEAR(@OracleMinDate),
                    MONTH(@OracleMinDate),
                    1
                );
        END;


        /*========================================================
          5. 每次向前回補一個完整月份
        ========================================================*/
        IF ISNULL(@BackfillComplete, 0) = 0
           AND @BackfillBeforeDate IS NOT NULL
        BEGIN
            SET @BackfillToDate =
                @BackfillBeforeDate;

            SET @BackfillFromDate =
                DATEADD(MONTH, -1, @BackfillToDate);

            SET @DoBackfill = 1;
        END;


        SET @RecentFromText =
            CONVERT(CHAR(10), @RecentFromDate, 23);

        SET @RecentToText =
            CONVERT(CHAR(10), @RecentToDate, 23);


        IF @DoBackfill = 1
        BEGIN
            SET @BackfillFromText =
                CONVERT(CHAR(10), @BackfillFromDate, 23);

            SET @BackfillToText =
                CONVERT(CHAR(10), @BackfillToDate, 23);
        END;


        /*========================================================
          6. Oracle TLFS 暫存
        ========================================================*/
        DROP TABLE IF EXISTS #TlfsSource;

        CREATE TABLE #TlfsSource
        (
              ItemNo             NVARCHAR(100) NULL
            , WarehouseNo        NVARCHAR(50)  NULL
            , LocationNo         NVARCHAR(50)  NULL
            , LotNo              NVARCHAR(100) NULL
            , SerialNo           NVARCHAR(100) NULL
            , ManufacturingLotNo NVARCHAR(100) NULL
            , ActivityDate       DATE          NULL
        );


        /*========================================================
          7. M302 Oracle 查詢
             與 SNX CIMQ001 相同：使用 TLFS12
        ========================================================*/
        SET @OracleSql =
              N'SELECT DISTINCT'
            + N'       tlfs01,'
            + N'       tlfs02,'
            + N'       tlfs03,'
            + N'       tlfs04,'
            + N'       tlfs05,'
            + N'       tlfs06,'
            + N'       TRUNC(tlfs12) AS tlfs12 '
            + N'FROM M302_2023.tlfs_file '
            + N'WHERE tlfs12 >= TO_DATE('
            + @Quote + @RecentFromText + @Quote
            + N',' + @Quote + N'YYYY-MM-DD' + @Quote + N') '
            + N'  AND tlfs12 < TO_DATE('
            + @Quote + @RecentToText + @Quote
            + N',' + @Quote + N'YYYY-MM-DD' + @Quote + N')';


        IF @DoBackfill = 1
        BEGIN
            SET @OracleSql =
                  @OracleSql
                + N' UNION '
                + N'SELECT DISTINCT'
                + N'       tlfs01,'
                + N'       tlfs02,'
                + N'       tlfs03,'
                + N'       tlfs04,'
                + N'       tlfs05,'
                + N'       tlfs06,'
                + N'       TRUNC(tlfs12) AS tlfs12 '
                + N'FROM M302_2023.tlfs_file '
                + N'WHERE tlfs12 >= TO_DATE('
                + @Quote + @BackfillFromText + @Quote
                + N',' + @Quote + N'YYYY-MM-DD' + @Quote + N') '
                + N'  AND tlfs12 < TO_DATE('
                + @Quote + @BackfillToText + @Quote
                + N',' + @Quote + N'YYYY-MM-DD' + @Quote + N')';
        END;


        /*========================================================
          8. OPENQUERY
        ========================================================*/
        SET @Command =
              N'INSERT INTO #TlfsSource'
            + N'('
            + N'    ItemNo,'
            + N'    WarehouseNo,'
            + N'    LocationNo,'
            + N'    LotNo,'
            + N'    SerialNo,'
            + N'    ManufacturingLotNo,'
            + N'    ActivityDate'
            + N') '
            + N'SELECT'
            + N'    CONVERT(NVARCHAR(100), TLFS01),'
            + N'    CONVERT(NVARCHAR(50),  TLFS02),'
            + N'    CONVERT(NVARCHAR(50),  TLFS03),'
            + N'    CONVERT(NVARCHAR(100), TLFS04),'
            + N'    CONVERT(NVARCHAR(100), TLFS05),'
            + N'    CONVERT(NVARCHAR(100), TLFS06),'
            + N'    TRY_CONVERT(DATE, TLFS12) '
            + N'FROM OPENQUERY'
            + N'('
            + N'    [ORACLE_LINKED_SERVER], '
            + @Quote
            + REPLACE
              (
                  @OracleSql,
                  @Quote,
                  @Quote + @Quote
              )
            + @Quote
            + N');';


        EXEC sys.sp_executesql @Command;


        SELECT
            @SourceRows = COUNT_BIG(*)
        FROM #TlfsSource;


        /*========================================================
          9. 只對應 M302 Snapshot

             這裡非常重要：
             不再用 ta_ima01 判斷營運中心。
        ========================================================*/
        DROP TABLE IF EXISTS #ActivityLoad;

        SELECT DISTINCT
              s.InventoryKey
            , t.ActivityDate
            , CAST(N'TLFS' AS VARCHAR(10)) AS ActivityType
            , s.imgs01 AS ItemNo
            , s.imgs02 AS WarehouseNo
            , s.imgs03 AS LocationNo
            , s.imgs04 AS LotNo
            , s.imgs05 AS SerialNo
            , s.imgs06 AS ManufacturingLotNo
            , @LoadBatchId AS LoadBatchId
            , @LoadedAt AS LoadedAt
            , CAST(N'M302' AS NVARCHAR(20)) AS OperatingCenter
        INTO #ActivityLoad
        FROM #TlfsSource AS t
        INNER JOIN dbo.InventoryInquirySnapshot AS s
            ON RTRIM(t.ItemNo)
                   COLLATE Latin1_General_100_BIN2
             = RTRIM(s.imgs01)
                   COLLATE Latin1_General_100_BIN2

           AND RTRIM(t.WarehouseNo)
                   COLLATE Latin1_General_100_BIN2
             = RTRIM(s.imgs02)
                   COLLATE Latin1_General_100_BIN2

           AND RTRIM(t.LocationNo)
                   COLLATE Latin1_General_100_BIN2
             = RTRIM(s.imgs03)
                   COLLATE Latin1_General_100_BIN2

           AND RTRIM(t.LotNo)
                   COLLATE Latin1_General_100_BIN2
             = RTRIM(s.imgs04)
                   COLLATE Latin1_General_100_BIN2

           AND ISNULL(RTRIM(t.SerialNo), N'')
                   COLLATE Latin1_General_100_BIN2
             = ISNULL(RTRIM(s.imgs05), N'')
                   COLLATE Latin1_General_100_BIN2

           AND ISNULL(RTRIM(t.ManufacturingLotNo), N'')
                   COLLATE Latin1_General_100_BIN2
             = ISNULL(RTRIM(s.imgs06), N'')
                   COLLATE Latin1_General_100_BIN2

        WHERE t.ActivityDate IS NOT NULL
          AND s.OperatingCenter = N'M302';


        CREATE UNIQUE CLUSTERED INDEX CIX_ActivityLoad
        ON #ActivityLoad
        (
              InventoryKey
            , ActivityDate
            , ActivityType
        );


        BEGIN TRANSACTION;


        /*========================================================
          10. 只刪 M302 本次日期範圍

              不可影響 SNX / GFUN。
        ========================================================*/
        DELETE a
        FROM dbo.InventoryInquiryActivity AS a
        WHERE a.ActivityType = N'TLFS'
          AND a.OperatingCenter = N'M302'
          AND
          (
                (
                    a.ActivityDate >= @RecentFromDate
                    AND a.ActivityDate < @RecentToDate
                )
                OR
                (
                    @DoBackfill = 1
                    AND a.ActivityDate >= @BackfillFromDate
                    AND a.ActivityDate < @BackfillToDate
                )
          );


        /*========================================================
          11. 寫入 M302 Activity
        ========================================================*/
        INSERT INTO dbo.InventoryInquiryActivity
        (
              InventoryKey
            , ActivityDate
            , ActivityType
            , ItemNo
            , WarehouseNo
            , LocationNo
            , LotNo
            , SerialNo
            , ManufacturingLotNo
            , LoadBatchId
            , LoadedAt
            , OperatingCenter
        )
        SELECT
              InventoryKey
            , ActivityDate
            , ActivityType
            , ItemNo
            , WarehouseNo
            , LocationNo
            , LotNo
            , SerialNo
            , ManufacturingLotNo
            , LoadBatchId
            , LoadedAt
            , OperatingCenter
        FROM #ActivityLoad;


        SET @InsertedRows = @@ROWCOUNT;


        /*========================================================
          12. 更新 M302 自己的回補狀態
        ========================================================*/
        UPDATE dbo.InventoryInquiryActivityLoadState
        SET
              BackfillBeforeDate =
                  CASE
                      WHEN @DoBackfill = 1
                          THEN @BackfillFromDate
                      ELSE BackfillBeforeDate
                  END

            , BackfillComplete =
                  CASE
                      WHEN @DoBackfill = 1
                       AND @OracleMinMonth IS NOT NULL
                       AND @BackfillFromDate <= @OracleMinMonth
                          THEN 1
                      ELSE BackfillComplete
                  END

            , LastSourceRows = @SourceRows
            , LastInsertedRows = @InsertedRows
            , LastSuccessfulAt = @LoadedAt

        WHERE ProcessName = @ProcessName;


        COMMIT TRANSACTION;


        /*========================================================
          13. 執行結果
        ========================================================*/
        SELECT
              @SourceRows AS OracleSourceRows
            , @InsertedRows AS InsertedRows
            , @RecentFromDate AS RecentFromDate
            , DATEADD(DAY, -1, @RecentToDate) AS RecentToDate
            , @BackfillFromDate AS BackfillFromDate
            , CASE
                  WHEN @DoBackfill = 1
                      THEN DATEADD(DAY, -1, @BackfillToDate)
                  ELSE NULL
              END AS BackfillToDate
            , BackfillBeforeDate AS NextBackfillBeforeDate
            , BackfillComplete
            , LastSuccessfulAt
            , N'M302' AS OperatingCenter
        FROM dbo.InventoryInquiryActivityLoadState
        WHERE ProcessName = @ProcessName;


        EXEC sys.sp_releaseapplock
              @Resource = N'SAL_MRT.InventoryInquiryActivity.TLFS.M302'
            , @LockOwner = N'Session';

    END TRY

    BEGIN CATCH

        IF @@TRANCOUNT > 0
            ROLLBACK TRANSACTION;

        EXEC sys.sp_releaseapplock
              @Resource = N'SAL_MRT.InventoryInquiryActivity.TLFS.M302'
            , @LockOwner = N'Session';

        THROW;

    END CATCH;
END;

GO
