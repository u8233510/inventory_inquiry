USE [SAL_MRT];
GO




/*
===============================================================================
dbo.sp_Update_InventoryInquiryPerson
===============================================================================
用途：
  依 cimq001.4gl 原始流程，更新：
    1. InventoryInquirySnapshot.sfu16
    2. InventoryInquirySnapshot.sfu16_desc

處理流程：
  A. 判斷 imgs06 是否為顏色（agd_file）。
  B. 一般製造批號：
       透過 tc_imga_file / tc_img_file / tc_imgb_file，
       最多回溯 30 次取得原始製造批號。
  C. 顏色：
       依完整庫存鍵查最近一筆 tlfs_file 入項；
       若為調撥 aimt32 / cimt32，透過 tlf_file 往前追；
       若為轉批 asft62 / csft62，透過 tc_img* 往前追。
  D. 依 4GL 順序取得人員：
       1. SFV -> SFB.sfb44
       2. RVV -> RVU.rvu07
       3. RVA.rva33
       4. INA.ina11
  E. 以上查不到時，再以 S027 來源單號重查。
     來源單號備援依 4GL 原碼：SFV -> RVU -> INA。
     4GL 原碼連續呼叫兩次 RVU，第二次不會增加結果，因此不重複執行。

參數：
  @AsOfDate
      對應 4GL 的 tm.edate。
      NULL 時取 M302 InventoryInquiryActivity 最新 TLFS 異動日期。

  @OnlyMissing
      1：只處理目前 sfu16 空白的 Snapshot，預設值。
      0：重新計算全部 Snapshot，但只有找到人員時才覆寫。

  @MaxRows
      NULL：處理全部符合資料。
      大於 0：只處理指定筆數，供小批次驗證。

資料來源：
  1. tlfs_file：直接讀取 [ORACLE_LINKED_SERVER].M302_2023.tlfs_file。
  2. sfv_file、sfb_file、gen_file：維持讀取 ERP_Staging。
  3. 其他回溯表：維持原本 ERP_Staging 來源。

重要：
  本 SP 僅處理 OperatingCenter = 'M302' 的 Snapshot / Activity。
  本 SP 不重建 Snapshot，不修改 Activity，不修改平均成本。
===============================================================================
*/

CREATE   PROCEDURE dbo.sp_Update_InventoryInquiryPerson_M302
(
      @AsOfDate   DATE = NULL
    , @OnlyMissing BIT = 1
    , @MaxRows     INT = NULL
)
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    IF @AsOfDate IS NULL
    BEGIN
        SELECT
            @AsOfDate = MAX(a.ActivityDate)
        FROM dbo.InventoryInquiryActivity AS a
        WHERE a.ActivityType = N'TLFS'
          AND a.OperatingCenter = N'M302';
    END;

    IF @AsOfDate IS NULL
        SET @AsOfDate = CONVERT(DATE, GETDATE());

    IF @MaxRows IS NOT NULL AND @MaxRows <= 0
        THROW 50301, N'@MaxRows 必須為 NULL 或大於 0。', 1;

    IF COL_LENGTH(N'dbo.InventoryInquirySnapshot', N'OperatingCenter') IS NULL
        THROW 50307, N'InventoryInquirySnapshot 缺少 OperatingCenter 欄位。', 1;

    IF COL_LENGTH(N'dbo.InventoryInquiryActivity', N'OperatingCenter') IS NULL
        THROW 50308, N'InventoryInquiryActivity 缺少 OperatingCenter 欄位。', 1;

    IF OBJECT_ID(N'ERP_Staging.dbo.m302_agd_file', N'U') IS NULL
        THROW 50302, N'缺少 ERP_Staging.dbo.m302_agd_file。', 1;

    IF NOT EXISTS
    (
        SELECT 1
        FROM sys.servers
        WHERE name = N'ORACLE_LINKED_SERVER'
    )
        THROW 50303, N'缺少 Linked Server：ORACLE_LINKED_SERVER。', 1;

    IF OBJECT_ID(N'ERP_Staging.dbo.m302_tc_img_file', N'U') IS NULL
        THROW 50304, N'缺少 ERP_Staging.dbo.m302_tc_img_file。', 1;

    IF OBJECT_ID(N'ERP_Staging.dbo.m302_tc_imga_file', N'U') IS NULL
        THROW 50305, N'缺少 ERP_Staging.dbo.m302_tc_imga_file。', 1;

    IF OBJECT_ID(N'ERP_Staging.dbo.m302_tc_imgb_file', N'U') IS NULL
        THROW 50306, N'缺少 ERP_Staging.dbo.m302_tc_imgb_file。', 1;

    DROP TABLE IF EXISTS #Work;
    DROP TABLE IF EXISTS #Resolved;
    DROP TABLE IF EXISTS #NextTrace;
    DROP TABLE IF EXISTS #SearchKey;
    DROP TABLE IF EXISTS #PersonCandidate;
    DROP TABLE IF EXISTS #PrimaryBest;
    DROP TABLE IF EXISTS #FallbackBest;
    DROP TABLE IF EXISTS #OracleTlfsTrace;
    DROP TABLE IF EXISTS #OracleTlfsPerson;
    DROP TABLE IF EXISTS #TracePullKey;
    DROP TABLE IF EXISTS #PersonPullKey;

    /*
    ===========================================================================
    1. 取出本次要處理的 Snapshot
    ===========================================================================
    */
    SELECT TOP
    (
        CASE
            WHEN @MaxRows IS NULL THEN 2147483647
            ELSE @MaxRows
        END
    )
          s.InventoryKey
        , CONVERT(NVARCHAR(40), s.imgs01)
            COLLATE Chinese_Taiwan_Stroke_CI_AS AS ItemNo
        , CONVERT(NVARCHAR(40), s.imgs02)
            COLLATE Chinese_Taiwan_Stroke_CI_AS AS WarehouseNo
        , CONVERT(NVARCHAR(40), s.imgs03)
            COLLATE Chinese_Taiwan_Stroke_CI_AS AS LocationNo
        , CONVERT(NVARCHAR(40), s.imgs04)
            COLLATE Chinese_Taiwan_Stroke_CI_AS AS LotOrderNo
        , CONVERT(NVARCHAR(40), s.imgs05)
            COLLATE Chinese_Taiwan_Stroke_CI_AS AS SerialNo
        , CONVERT(NVARCHAR(40), s.imgs06)
            COLLATE Chinese_Taiwan_Stroke_CI_AS AS ManufacturingLot
        , NULLIF
          (
              LTRIM(RTRIM(CONVERT(NVARCHAR(40), s.source_order))),
              N''
          ) COLLATE Chinese_Taiwan_Stroke_CI_AS AS SourceOrder
    INTO #Work
    FROM dbo.InventoryInquirySnapshot AS s
    WHERE s.OperatingCenter = N'M302'
      AND
      (
          @OnlyMissing = 0
          OR NULLIF(LTRIM(RTRIM(CONVERT(NVARCHAR(100), s.sfu16))), N'')
             IS NULL
      )
    ORDER BY s.InventoryKey;

    CREATE UNIQUE CLUSTERED INDEX IX_Work_InventoryKey
        ON #Work(InventoryKey);

    IF NOT EXISTS (SELECT 1 FROM #Work)
    BEGIN
        SELECT
              @AsOfDate AS [計算截止日]
            , 0 AS [本次處理筆數]
            , 0 AS [更新筆數]
            , 0 AS [仍無人員筆數];
        RETURN;
    END;

    /*
    ===========================================================================
    2. 建立回溯狀態
    ===========================================================================
    */
    SELECT
          w.InventoryKey
        , w.ItemNo
        , w.WarehouseNo
        , w.LocationNo
        , w.LotOrderNo
        , w.SerialNo
        , w.ManufacturingLot
        , w.SourceOrder

        , CASE
            WHEN EXISTS
            (
                SELECT 1
                FROM ERP_Staging.dbo.m302_agd_file AS agd
                WHERE agd.agd02 = w.ManufacturingLot
            )
            THEN CONVERT(BIT, 1)
            ELSE CONVERT(BIT, 0)
          END AS IsColor

        , w.WarehouseNo AS CurrentWarehouse
        , w.LocationNo AS CurrentLocation
        , w.LotOrderNo AS CurrentLotOrder
        , w.SerialNo AS CurrentSerial
        , w.ManufacturingLot AS ResolvedKey

        , CONVERT(BIT, 0) AS TraceDone
        , CAST(N'原製造批號' AS NVARCHAR(100)) AS TracePath
    INTO #Resolved
    FROM #Work AS w;

    CREATE UNIQUE CLUSTERED INDEX IX_Resolved_InventoryKey
        ON #Resolved(InventoryKey);

    CREATE INDEX IX_Resolved_Key
        ON #Resolved(ResolvedKey);


    /*
    ===========================================================================
    2-1. 從 Oracle 直接載入「顏色回溯」所需的 tlfs_file

    只依本次 Snapshot 中的「料號 + 製造批號」分批查詢，
    不把整張 tlfs_file 拉回 SQL Server。
    ===========================================================================
    */
    CREATE TABLE #OracleTlfsTrace
    (
          tlfs01  NVARCHAR(40)  COLLATE Chinese_Taiwan_Stroke_CI_AS NULL
        , tlfs02  NVARCHAR(40)  COLLATE Chinese_Taiwan_Stroke_CI_AS NULL
        , tlfs03  NVARCHAR(40)  COLLATE Chinese_Taiwan_Stroke_CI_AS NULL
        , tlfs04  NVARCHAR(40)  COLLATE Chinese_Taiwan_Stroke_CI_AS NULL
        , tlfs05  NVARCHAR(40)  COLLATE Chinese_Taiwan_Stroke_CI_AS NULL
        , tlfs06  NVARCHAR(40)  COLLATE Chinese_Taiwan_Stroke_CI_AS NULL
        , tlfs08  NVARCHAR(100) COLLATE Chinese_Taiwan_Stroke_CI_AS NULL
        , tlfs09  DECIMAL(18,0) NULL
        , tlfs10  NVARCHAR(40)  COLLATE Chinese_Taiwan_Stroke_CI_AS NULL
        , tlfs11  DECIMAL(18,0) NULL
        , tlfs12  DATETIME2(0)  NULL
        , tlfs111 NVARCHAR(40)  COLLATE Chinese_Taiwan_Stroke_CI_AS NULL
    );

    ;WITH K AS
    (
        SELECT DISTINCT
              r.ItemNo
            , r.ResolvedKey
        FROM #Resolved AS r
        WHERE r.IsColor = 1
          AND NULLIF(LTRIM(RTRIM(r.ItemNo)), N'') IS NOT NULL
          AND NULLIF(LTRIM(RTRIM(r.ResolvedKey)), N'') IS NOT NULL
    ), N AS
    (
        SELECT
              ItemNo
            , ResolvedKey
            , ROW_NUMBER() OVER (ORDER BY ItemNo, ResolvedKey) AS rn
        FROM K
    )
    SELECT
          ItemNo
        , ResolvedKey
        , ((rn - 1) / 100) + 1 AS BatchNo
    INTO #TracePullKey
    FROM N;

    DECLARE
          @PullBatch INT = 1
        , @PullBatchMax INT = ISNULL((SELECT MAX(BatchNo) FROM #TracePullKey), 0)
        , @OraclePredicate NVARCHAR(MAX)
        , @OracleQuery NVARCHAR(MAX)
        , @PullSql NVARCHAR(MAX)
        , @OracleCutoff CHAR(10) = CONVERT(CHAR(10), DATEADD(DAY, 1, @AsOfDate), 120);

    WHILE @PullBatch <= @PullBatchMax
    BEGIN
        SELECT
            @OraclePredicate = STRING_AGG
            (
                CONVERT
                (
                    NVARCHAR(MAX),
                    N'(RTRIM(tlfs01) = '''
                    + REPLACE(ItemNo, N'''', N'''''')
                    + N''' AND RTRIM(tlfs06) = '''
                    + REPLACE(ResolvedKey, N'''', N'''''')
                    + N''')'
                ),
                N' OR '
            )
        FROM #TracePullKey
        WHERE BatchNo = @PullBatch;

        SET @OracleQuery =
              N'SELECT '
            + N'RTRIM(tlfs01) tlfs01, RTRIM(tlfs02) tlfs02, '
            + N'RTRIM(tlfs03) tlfs03, RTRIM(tlfs04) tlfs04, '
            + N'RTRIM(tlfs05) tlfs05, RTRIM(tlfs06) tlfs06, '
            + N'RTRIM(tlfs08) tlfs08, tlfs09, RTRIM(tlfs10) tlfs10, '
            + N'tlfs11, TO_CHAR(tlfs12,''YYYY-MM-DD HH24:MI:SS'') tlfs12, '
            + N'RTRIM(tlfs111) tlfs111 '
            + N'FROM M302_2023.tlfs_file '
            + N'WHERE tlfs09 = 1 '
            + N'AND tlfs12 < TO_DATE(''' + @OracleCutoff + N''',''YYYY-MM-DD'') '
            + N'AND (' + @OraclePredicate + N')';

        SET @PullSql =
              N'INSERT INTO #OracleTlfsTrace '
            + N'(tlfs01,tlfs02,tlfs03,tlfs04,tlfs05,tlfs06,tlfs08,'
            + N' tlfs09,tlfs10,tlfs11,tlfs12,tlfs111) '
            + N'SELECT '
            + N'CONVERT(NVARCHAR(40),q.tlfs01), '
            + N'CONVERT(NVARCHAR(40),q.tlfs02), '
            + N'CONVERT(NVARCHAR(40),q.tlfs03), '
            + N'CONVERT(NVARCHAR(40),q.tlfs04), '
            + N'CONVERT(NVARCHAR(40),q.tlfs05), '
            + N'CONVERT(NVARCHAR(40),q.tlfs06), '
            + N'CONVERT(NVARCHAR(100),q.tlfs08), '
            + N'TRY_CONVERT(DECIMAL(18,0),q.tlfs09), '
            + N'CONVERT(NVARCHAR(40),q.tlfs10), '
            + N'TRY_CONVERT(DECIMAL(18,0),q.tlfs11), '
            + N'TRY_CONVERT(DATETIME2(0),q.tlfs12), '
            + N'CONVERT(NVARCHAR(40),q.tlfs111) '
            + N'FROM OPENQUERY([ORACLE_LINKED_SERVER], '''
            + REPLACE(@OracleQuery, N'''', N'''''')
            + N''') AS q;';

        EXEC sys.sp_executesql @PullSql;
        SET @PullBatch += 1;
    END;

    CREATE INDEX IX_OracleTlfsTrace_Lookup
        ON #OracleTlfsTrace
        (
              tlfs01
            , tlfs02
            , tlfs03
            , tlfs04
            , tlfs05
            , tlfs06
            , tlfs12
        )
        INCLUDE (tlfs08, tlfs09, tlfs10, tlfs11, tlfs111);

    /*
    ===========================================================================
    3. 一般製造批號：依 q001_get_tc_imgb07 最多回溯 30 次

    4GL 條件：
      tc_imga19 = 目前製造批號
      tc_img03  = 料號
      NVL(tc_imga05,' ') = NVL(目前批號,' ')

    4GL 輸出：
      tc_imgb07、tc_imgb03、tc_imgb04、tc_imgb05
    ===========================================================================
    */
    DECLARE @TraceLoop INT = 1;
    DECLARE @TraceRows INT = 1;

    WHILE @TraceLoop <= 30 AND @TraceRows > 0
    BEGIN
        DROP TABLE IF EXISTS #NextTrace;

        SELECT
              r.InventoryKey
            , x.PrevLot
            , x.PrevWarehouse
            , x.PrevLocation
            , x.PrevLotOrder
        INTO #NextTrace
        FROM #Resolved AS r
        OUTER APPLY
        (
            SELECT TOP (1)
                  CONVERT(NVARCHAR(40), b.tc_imgb07)
                      COLLATE Chinese_Taiwan_Stroke_CI_AS AS PrevLot
                , CONVERT(NVARCHAR(40), b.tc_imgb03)
                      COLLATE Chinese_Taiwan_Stroke_CI_AS AS PrevWarehouse
                , CONVERT(NVARCHAR(40), b.tc_imgb04)
                      COLLATE Chinese_Taiwan_Stroke_CI_AS AS PrevLocation
                , CONVERT(NVARCHAR(40), b.tc_imgb05)
                      COLLATE Chinese_Taiwan_Stroke_CI_AS AS PrevLotOrder
            FROM ERP_Staging.dbo.m302_tc_imga_file AS a
            INNER JOIN ERP_Staging.dbo.m302_tc_img_file AS h
                ON h.tc_img01 = a.tc_imga01
               AND h.tc_imgconf = N'Y'
            INNER JOIN ERP_Staging.dbo.m302_tc_imgb_file AS b
                ON b.tc_imgb01 = h.tc_img01
               AND b.tc_imgb31 = a.tc_imga31
            WHERE a.tc_imga19 = r.ResolvedKey
              AND h.tc_img03 = r.ItemNo
              AND ISNULL(a.tc_imga05, N'')
                  = ISNULL(r.CurrentLotOrder, N'')
              AND NULLIF(LTRIM(RTRIM(b.tc_imgb07)), N'') IS NOT NULL
            ORDER BY
                  b.tc_imgb07
                , b.tc_imgb31
        ) AS x
        WHERE r.IsColor = 0
          AND r.TraceDone = 0;

        CREATE UNIQUE CLUSTERED INDEX IX_NextTrace
            ON #NextTrace(InventoryKey);

        UPDATE r
           SET r.ResolvedKey =
                   CASE
                       WHEN n.PrevLot IS NOT NULL
                            AND n.PrevLot <> r.ResolvedKey
                       THEN n.PrevLot
                       ELSE r.ResolvedKey
                   END,
               r.CurrentWarehouse =
                   CASE WHEN n.PrevLot IS NOT NULL
                        THEN n.PrevWarehouse
                        ELSE r.CurrentWarehouse
                   END,
               r.CurrentLocation =
                   CASE WHEN n.PrevLot IS NOT NULL
                        THEN n.PrevLocation
                        ELSE r.CurrentLocation
                   END,
               r.CurrentLotOrder =
                   CASE WHEN n.PrevLot IS NOT NULL
                        THEN n.PrevLotOrder
                        ELSE r.CurrentLotOrder
                   END,
               r.TracePath =
                   CASE WHEN n.PrevLot IS NOT NULL
                        THEN N'一般製造批號→轉批回溯'
                        ELSE r.TracePath
                   END,
               r.TraceDone =
                   CASE
                       WHEN n.PrevLot IS NULL
                            OR n.PrevLot = r.ResolvedKey
                       THEN 1
                       ELSE 0
                   END
        FROM #Resolved AS r
        INNER JOIN #NextTrace AS n
            ON n.InventoryKey = r.InventoryKey;

        SET @TraceRows =
        (
            SELECT COUNT(*)
            FROM #NextTrace
            WHERE PrevLot IS NOT NULL
        );

        SET @TraceLoop += 1;
    END;

    UPDATE #Resolved
       SET TraceDone = 1
    WHERE IsColor = 0;

    /*
    ===========================================================================
    4. 顏色資料：依 4GL 逐筆追溯

    顏色資料才使用 Cursor；一般製造批號已在上一步批次處理。
    ===========================================================================
    */
    DECLARE
          @InventoryKey VARBINARY(32)
        , @ItemNo NVARCHAR(40)
        , @CurrentWarehouse NVARCHAR(40)
        , @CurrentLocation NVARCHAR(40)
        , @CurrentLotOrder NVARCHAR(40)
        , @CurrentSerial NVARCHAR(40)
        , @ResolvedKey NVARCHAR(40)
        , @TracePath NVARCHAR(100)

        , @OuterLoop INT
        , @InnerLoop INT
        , @TransferLoop INT
        , @Found BIT
        , @CurrentIsColor BIT

        , @Tlfs02 NVARCHAR(40)
        , @Tlfs03 NVARCHAR(40)
        , @Tlfs04 NVARCHAR(40)
        , @Tlfs05 NVARCHAR(40)
        , @Tlfs06 NVARCHAR(40)
        , @Tlfs08 NVARCHAR(100)
        , @Tlfs10 NVARCHAR(40)
        , @Tlfs11 NUMERIC(18,0)
        , @Tlfs12 DATETIME2
        , @Tlfs111 NVARCHAR(40)

        , @LastTlfs10 NVARCHAR(40)
        , @TlfsCutoff DATETIME2

        , @PrevLot NVARCHAR(40)
        , @PrevWarehouse NVARCHAR(40)
        , @PrevLocation NVARCHAR(40)
        , @PrevLotOrder NVARCHAR(40)

        , @TlfWarehouse NVARCHAR(40)
        , @TlfLocation NVARCHAR(40)
        , @TlfLotOrder NVARCHAR(40);

    DECLARE ColorCursor CURSOR LOCAL FAST_FORWARD FOR
    SELECT
          InventoryKey
        , ItemNo
        , CurrentWarehouse
        , CurrentLocation
        , CurrentLotOrder
        , CurrentSerial
        , ResolvedKey
        , TracePath
    FROM #Resolved
    WHERE IsColor = 1;

    OPEN ColorCursor;

    FETCH NEXT FROM ColorCursor INTO
          @InventoryKey
        , @ItemNo
        , @CurrentWarehouse
        , @CurrentLocation
        , @CurrentLotOrder
        , @CurrentSerial
        , @ResolvedKey
        , @TracePath;

    WHILE @@FETCH_STATUS = 0
    BEGIN
        SET @OuterLoop = 0;

        WHILE @OuterLoop < 20
        BEGIN
            SET @OuterLoop += 1;

            SET @CurrentIsColor =
            (
                CASE
                    WHEN EXISTS
                    (
                        SELECT 1
                        FROM ERP_Staging.dbo.m302_agd_file AS agd
                        WHERE agd.agd02 = @ResolvedKey
                    )
                    THEN 1 ELSE 0
                END
            );

            /*
            若轉批後已回到一般製造批號，改走一般轉批回溯。
            */
            IF @CurrentIsColor = 0
            BEGIN
                SET @TransferLoop = 0;

                WHILE @TransferLoop < 30
                BEGIN
                    SET @TransferLoop += 1;

                    SET @PrevLot = NULL;
                    SET @PrevWarehouse = NULL;
                    SET @PrevLocation = NULL;
                    SET @PrevLotOrder = NULL;

                    SELECT TOP (1)
                          @PrevLot =
                              CONVERT(NVARCHAR(40), b.tc_imgb07)
                        , @PrevWarehouse =
                              CONVERT(NVARCHAR(40), b.tc_imgb03)
                        , @PrevLocation =
                              CONVERT(NVARCHAR(40), b.tc_imgb04)
                        , @PrevLotOrder =
                              CONVERT(NVARCHAR(40), b.tc_imgb05)
                    FROM ERP_Staging.dbo.m302_tc_imga_file AS a
                    INNER JOIN ERP_Staging.dbo.m302_tc_img_file AS h
                        ON h.tc_img01 = a.tc_imga01
                       AND h.tc_imgconf = N'Y'
                    INNER JOIN ERP_Staging.dbo.m302_tc_imgb_file AS b
                        ON b.tc_imgb01 = h.tc_img01
                       AND b.tc_imgb31 = a.tc_imga31
                    WHERE a.tc_imga19 = @ResolvedKey
                      AND h.tc_img03 = @ItemNo
                      AND ISNULL(a.tc_imga05, N'')
                          = ISNULL(@CurrentLotOrder, N'')
                      AND NULLIF(LTRIM(RTRIM(b.tc_imgb07)), N'')
                          IS NOT NULL
                    ORDER BY
                          b.tc_imgb07
                        , b.tc_imgb31;

                    IF @PrevLot IS NULL OR @PrevLot = @ResolvedKey
                        BREAK;

                    SET @ResolvedKey = @PrevLot;
                    SET @CurrentWarehouse = @PrevWarehouse;
                    SET @CurrentLocation = @PrevLocation;
                    SET @CurrentLotOrder = @PrevLotOrder;
                    SET @TracePath = N'顏色→一般製造批號→轉批回溯';
                END;

                BREAK;
            END;

            /*
            q001_get_tlfs_c：
            先取最近一次入項；若為調撥，沿 tlf_file 往前追。
            */
            SET @InnerLoop = 0;
            SET @LastTlfs10 = N'ABCZZZZZZZ';
            SET @TlfsCutoff =
                DATEADD(DAY, 1, CONVERT(DATETIME2, @AsOfDate));
            SET @Found = 0;

            WHILE @InnerLoop < 6
            BEGIN
                SET @InnerLoop += 1;
                SET @Found = 0;

                SET @Tlfs02 = NULL;
                SET @Tlfs03 = NULL;
                SET @Tlfs04 = NULL;
                SET @Tlfs05 = NULL;
                SET @Tlfs06 = NULL;
                SET @Tlfs08 = NULL;
                SET @Tlfs10 = NULL;
                SET @Tlfs11 = NULL;
                SET @Tlfs12 = NULL;
                SET @Tlfs111 = NULL;

                SELECT TOP (1)
                      @Tlfs02 = CONVERT(NVARCHAR(40), f.tlfs02)
                    , @Tlfs03 = CONVERT(NVARCHAR(40), f.tlfs03)
                    , @Tlfs04 = CONVERT(NVARCHAR(40), f.tlfs04)
                    , @Tlfs05 = CONVERT(NVARCHAR(40), f.tlfs05)
                    , @Tlfs06 = CONVERT(NVARCHAR(40), f.tlfs06)
                    , @Tlfs08 = CONVERT(NVARCHAR(100), f.tlfs08)
                    , @Tlfs10 = CONVERT(NVARCHAR(40), f.tlfs10)
                    , @Tlfs11 = TRY_CONVERT(NUMERIC(5,0), f.tlfs11)
                    , @Tlfs12 = TRY_CONVERT(DATETIME2, f.tlfs12)
                    , @Tlfs111 = CONVERT(NVARCHAR(40), f.tlfs111)
                    , @Found = 1
                FROM #OracleTlfsTrace AS f
                WHERE f.tlfs01 = @ItemNo
                  AND f.tlfs02 = @CurrentWarehouse
                  AND f.tlfs03 = @CurrentLocation
                  AND f.tlfs04 = @CurrentLotOrder
                  AND
                  (
                      f.tlfs05 = @CurrentSerial
                      OR (f.tlfs05 IS NULL AND @CurrentSerial IS NULL)
                  )
                  AND f.tlfs06 = @ResolvedKey
                  AND f.tlfs09 = 1
                  AND f.tlfs10 <> @LastTlfs10
                  AND f.tlfs12 < @TlfsCutoff
                ORDER BY f.tlfs12 DESC;

                IF @Found = 0
                    BREAK;

                IF LEFT(ISNULL(@Tlfs08, N''), 6)
                   IN (N'aimt32', N'cimt32')
                BEGIN
                    SET @TlfWarehouse = NULL;
                    SET @TlfLocation = NULL;
                    SET @TlfLotOrder = NULL;

                    SELECT TOP (1)
                          @TlfWarehouse =
                              CONVERT(NVARCHAR(40), t.tlf902)
                        , @TlfLocation =
                              CONVERT(NVARCHAR(40), t.tlf903)
                        , @TlfLotOrder =
                              CONVERT(NVARCHAR(40), t.tlf904)
                    FROM ERP_Staging.dbo.m302_tlf_file AS t
                    WHERE t.tlf905 = @Tlfs10
                      AND t.tlf906 = @Tlfs11
                      AND t.tlf907 = -1;

                    IF @TlfWarehouse IS NULL
                        BREAK;

                    SET @CurrentWarehouse = @TlfWarehouse;
                    SET @CurrentLocation = @TlfLocation;
                    SET @CurrentLotOrder = @TlfLotOrder;
                    SET @CurrentSerial = @Tlfs05;
                    SET @ResolvedKey = @Tlfs06;
                    SET @LastTlfs10 = @Tlfs10;
                    SET @TlfsCutoff = @Tlfs12;
                    SET @TracePath = N'顏色→調撥回溯';

                    CONTINUE;
                END;

                BREAK;
            END;

            IF @Found = 0
                BREAK;

            /*
            asft62 / csft62：
            依 q001_get_tc_imgb07_1 回溯轉批前製造批號。
            */
            IF LEFT(ISNULL(@Tlfs08, N''), 6)
               IN (N'asft62', N'csft62')
               AND EXISTS
               (
                   SELECT 1
                   FROM ERP_Staging.dbo.m302_tc_img_file AS h
                   WHERE h.tc_imgconf = N'Y'
                     AND h.tc_img08 = @Tlfs10
               )
            BEGIN
                SET @CurrentWarehouse = @Tlfs02;
                SET @CurrentLocation = @Tlfs03;
                SET @CurrentLotOrder = @Tlfs04;
                SET @CurrentSerial = @Tlfs05;
                SET @ResolvedKey = @Tlfs06;
                SET @TracePath = N'顏色→轉批回溯';

                SET @TransferLoop = 0;

                WHILE @TransferLoop < 30
                BEGIN
                    SET @TransferLoop += 1;

                    SET @PrevLot = NULL;
                    SET @PrevWarehouse = NULL;
                    SET @PrevLocation = NULL;
                    SET @PrevLotOrder = NULL;

                    SELECT TOP (1)
                          @PrevLot =
                              CONVERT(NVARCHAR(40), b.tc_imgb07)
                        , @PrevWarehouse =
                              CONVERT(NVARCHAR(40), b.tc_imgb03)
                        , @PrevLocation =
                              CONVERT(NVARCHAR(40), b.tc_imgb04)
                        , @PrevLotOrder =
                              CONVERT(NVARCHAR(40), b.tc_imgb05)
                    FROM ERP_Staging.dbo.m302_tc_imga_file AS a
                    INNER JOIN ERP_Staging.dbo.m302_tc_img_file AS h
                        ON h.tc_img01 = a.tc_imga01
                       AND h.tc_imgconf = N'Y'
                    INNER JOIN ERP_Staging.dbo.m302_tc_imgb_file AS b
                        ON b.tc_imgb01 = h.tc_img01
                       AND b.tc_imgb31 = a.tc_imga31
                    WHERE a.tc_imga19 = @ResolvedKey
                      AND h.tc_img03 = @ItemNo
                      AND a.tc_imga03 = @CurrentWarehouse
                      AND ISNULL(a.tc_imga04, N'')
                          = ISNULL(@CurrentLocation, N'')
                      AND ISNULL(a.tc_imga05, N'')
                          = ISNULL(@CurrentLotOrder, N'')
                      AND EXISTS
                      (
                          SELECT 1
                          FROM ERP_Staging.dbo.m302_sfu_file AS u
                          WHERE u.sfu01 = h.tc_img08
                            AND u.sfu02 = @Tlfs111
                      )
                    ORDER BY
                          b.tc_imgb07
                        , b.tc_imgb31;

                    IF @PrevLot IS NULL OR @PrevLot = @ResolvedKey
                        BREAK;

                    SET @ResolvedKey = @PrevLot;
                    SET @CurrentWarehouse = @PrevWarehouse;
                    SET @CurrentLocation = @PrevLocation;
                    SET @CurrentLotOrder = @PrevLotOrder;
                END;

                /*
                對應 4GL CONTINUE WHILE：
                回到外層重新判斷新 ResolvedKey 是顏色或製造批號。
                */
                CONTINUE;
            END;

            /*
            非調撥、非轉批入項：
            4GL 將 l_imgs06 設為 tlfs10。
            */
            SET @ResolvedKey = @Tlfs10;
            SET @TracePath = N'顏色→TLFS來源單號';
            BREAK;
        END;

        UPDATE #Resolved
           SET ResolvedKey = @ResolvedKey,
               CurrentWarehouse = @CurrentWarehouse,
               CurrentLocation = @CurrentLocation,
               CurrentLotOrder = @CurrentLotOrder,
               CurrentSerial = @CurrentSerial,
               TracePath = @TracePath,
               TraceDone = 1
        WHERE InventoryKey = @InventoryKey;

        FETCH NEXT FROM ColorCursor INTO
              @InventoryKey
            , @ItemNo
            , @CurrentWarehouse
            , @CurrentLocation
            , @CurrentLotOrder
            , @CurrentSerial
            , @ResolvedKey
            , @TracePath;
    END;

    CLOSE ColorCursor;
    DEALLOCATE ColorCursor;

    /*
    ===========================================================================
    5. 建立需要查人的鍵值
    ===========================================================================
    */
    SELECT DISTINCT
        SearchKey
    INTO #SearchKey
    FROM
    (
        SELECT
            NULLIF(LTRIM(RTRIM(r.ResolvedKey)), N'') AS SearchKey
        FROM #Resolved AS r

        UNION

        SELECT
            NULLIF(LTRIM(RTRIM(r.SourceOrder)), N'')
        FROM #Resolved AS r
    ) AS K
    WHERE SearchKey IS NOT NULL;

    CREATE UNIQUE CLUSTERED INDEX IX_SearchKey
        ON #SearchKey(SearchKey);

    /*
    ===========================================================================
    5-0. 從 Oracle 直接載入「人員來源判斷」所需的 tlfs_file

    Oracle 的 IN 一次最多 1000 個值；此處每批 500 個 SearchKey。
    sfv_file、sfb_file、gen_file 仍使用 ERP_Staging。
    ===========================================================================
    */
    CREATE TABLE #OracleTlfsPerson
    (
          tlfs06 NVARCHAR(40) COLLATE Chinese_Taiwan_Stroke_CI_AS NULL
        , tlfs10 NVARCHAR(40) COLLATE Chinese_Taiwan_Stroke_CI_AS NULL
        , tlfs11 DECIMAL(18,0) NULL
        , tlfs12 DATETIME2(0) NULL
    );

    ;WITH N AS
    (
        SELECT
              SearchKey
            , ROW_NUMBER() OVER (ORDER BY SearchKey) AS rn
        FROM #SearchKey
    )
    SELECT
          SearchKey
        , ((rn - 1) / 500) + 1 AS BatchNo
    INTO #PersonPullKey
    FROM N;

    SET @PullBatch = 1;
    SET @PullBatchMax = ISNULL((SELECT MAX(BatchNo) FROM #PersonPullKey), 0);

    WHILE @PullBatch <= @PullBatchMax
    BEGIN
        SELECT
            @OraclePredicate = STRING_AGG
            (
                CONVERT
                (
                    NVARCHAR(MAX),
                    N'''' + REPLACE(SearchKey, N'''', N'''''') + N''''
                ),
                N','
            )
        FROM #PersonPullKey
        WHERE BatchNo = @PullBatch;

        SET @OracleQuery =
              N'SELECT RTRIM(tlfs06) tlfs06, RTRIM(tlfs10) tlfs10, '
            + N'tlfs11, TO_CHAR(tlfs12,''YYYY-MM-DD HH24:MI:SS'') tlfs12 '
            + N'FROM M302_2023.tlfs_file '
            + N'WHERE RTRIM(tlfs06) IN (' + @OraclePredicate + N')';

        SET @PullSql =
              N'INSERT INTO #OracleTlfsPerson (tlfs06,tlfs10,tlfs11,tlfs12) '
            + N'SELECT '
            + N'CONVERT(NVARCHAR(40),q.tlfs06), '
            + N'CONVERT(NVARCHAR(40),q.tlfs10), '
            + N'TRY_CONVERT(DECIMAL(18,0),q.tlfs11), '
            + N'TRY_CONVERT(DATETIME2(0),q.tlfs12) '
            + N'FROM OPENQUERY([ORACLE_LINKED_SERVER], '''
            + REPLACE(@OracleQuery, N'''', N'''''')
            + N''') AS q;';

        EXEC sys.sp_executesql @PullSql;
        SET @PullBatch += 1;
    END;

    CREATE INDEX IX_OracleTlfsPerson_Lookup
        ON #OracleTlfsPerson(tlfs06, tlfs10, tlfs11, tlfs12);

    CREATE TABLE #PersonCandidate
    (
          SearchKey NVARCHAR(40)
              COLLATE Chinese_Taiwan_Stroke_CI_AS NOT NULL
        , SourcePriority TINYINT NOT NULL
        , AllowFallback BIT NOT NULL
        , PersonId NVARCHAR(40) NULL
        , PersonName NVARCHAR(100) NULL
        , SourcePath NVARCHAR(20) NOT NULL
        , TlfsDate DATETIME2 NULL
    );

    /*
    5-1. q001_get_sfu16_p
    */
    INSERT INTO #PersonCandidate
    (
          SearchKey
        , SourcePriority
        , AllowFallback
        , PersonId
        , PersonName
        , SourcePath
        , TlfsDate
    )
    SELECT
          k.SearchKey
        , 1
        , 1
        , NULLIF(LTRIM(RTRIM(CONVERT(NVARCHAR(40), sfb.sfb44))), N'')
        , NULLIF(LTRIM(RTRIM(CONVERT(NVARCHAR(100), gen.gen02))), N'')
        , N'SFV/SFB'
        , TRY_CONVERT(DATETIME2, tlfs.tlfs12)
    FROM #SearchKey AS k
    INNER JOIN #OracleTlfsPerson AS tlfs
        ON tlfs.tlfs06 = k.SearchKey
    INNER JOIN ERP_Staging.dbo.m302_sfv_file AS sfv
        ON sfv.sfv01 = tlfs.tlfs10
       AND sfv.sfv03 = tlfs.tlfs11
    INNER JOIN ERP_Staging.dbo.m302_sfb_file AS sfb
        ON sfb.sfb01 = sfv.sfv11
    LEFT JOIN ERP_Staging.dbo.m302_gen_file AS gen
        ON gen.gen01 = sfb.sfb44
    WHERE NULLIF(LTRIM(RTRIM(sfb.sfb44)), N'') IS NOT NULL;

    /*
    5-2. q001_get_rvu07_p
    */
    INSERT INTO #PersonCandidate
    (
          SearchKey
        , SourcePriority
        , AllowFallback
        , PersonId
        , PersonName
        , SourcePath
        , TlfsDate
    )
    SELECT
          k.SearchKey
        , 2
        , 1
        , NULLIF(LTRIM(RTRIM(CONVERT(NVARCHAR(40), rvu.rvu07))), N'')
        , NULLIF(LTRIM(RTRIM(CONVERT(NVARCHAR(100), gen.gen02))), N'')
        , N'RVU'
        , TRY_CONVERT(DATETIME2, tlfs.tlfs12)
    FROM #SearchKey AS k
    INNER JOIN #OracleTlfsPerson AS tlfs
        ON tlfs.tlfs06 = k.SearchKey
    INNER JOIN ERP_Staging.dbo.m302_rvv_file AS rvv
        ON rvv.rvv01 = tlfs.tlfs10
       AND rvv.rvv02 = tlfs.tlfs11
    INNER JOIN ERP_Staging.dbo.m302_rvu_file AS rvu
        ON rvu.rvu01 = rvv.rvv01
       AND rvu.rvu00 = N'1'
       AND rvu.rvuconf = N'Y'
    LEFT JOIN ERP_Staging.dbo.m302_gen_file AS gen
        ON gen.gen01 = rvu.rvu07
    WHERE NULLIF(LTRIM(RTRIM(rvu.rvu07)), N'') IS NOT NULL;

    /*
    5-3. q001_get_rva33_p
    4GL 僅在主回溯鍵執行，來源單號備援沒有執行 RVA。
    */
    INSERT INTO #PersonCandidate
    (
          SearchKey
        , SourcePriority
        , AllowFallback
        , PersonId
        , PersonName
        , SourcePath
        , TlfsDate
    )
    SELECT
          k.SearchKey
        , 3
        , 0
        , NULLIF(LTRIM(RTRIM(CONVERT(NVARCHAR(40), rva.rva33))), N'')
        , NULLIF(LTRIM(RTRIM(CONVERT(NVARCHAR(100), gen.gen02))), N'')
        , N'RVA'
        , TRY_CONVERT(DATETIME2, tlfs.tlfs12)
    FROM #SearchKey AS k
    INNER JOIN #OracleTlfsPerson AS tlfs
        ON tlfs.tlfs06 = k.SearchKey
    INNER JOIN ERP_Staging.dbo.m302_rva_file AS rva
        ON rva.rva01 = tlfs.tlfs10
       AND rva.rvaconf = N'Y'
    LEFT JOIN ERP_Staging.dbo.m302_gen_file AS gen
        ON gen.gen01 = rva.rva33
    WHERE NULLIF(LTRIM(RTRIM(rva.rva33)), N'') IS NOT NULL;

    /*
    5-4. q001_get_ina11_p
    */
    INSERT INTO #PersonCandidate
    (
          SearchKey
        , SourcePriority
        , AllowFallback
        , PersonId
        , PersonName
        , SourcePath
        , TlfsDate
    )
    SELECT
          k.SearchKey
        , 4
        , 1
        , NULLIF(LTRIM(RTRIM(CONVERT(NVARCHAR(40), ina.ina11))), N'')
        , NULLIF(LTRIM(RTRIM(CONVERT(NVARCHAR(100), gen.gen02))), N'')
        , N'INA'
        , TRY_CONVERT(DATETIME2, tlfs.tlfs12)
    FROM #SearchKey AS k
    INNER JOIN #OracleTlfsPerson AS tlfs
        ON tlfs.tlfs06 = k.SearchKey
    INNER JOIN ERP_Staging.dbo.m302_ina_file AS ina
        ON ina.ina01 = tlfs.tlfs10
       AND ina.inaconf = N'Y'
       AND ina.inapost = N'Y'
       AND ina.ina00 IN (N'2', N'4')
    LEFT JOIN ERP_Staging.dbo.m302_gen_file AS gen
        ON gen.gen01 = ina.ina11
    WHERE NULLIF(LTRIM(RTRIM(ina.ina11)), N'') IS NOT NULL;

    CREATE INDEX IX_PersonCandidate
        ON #PersonCandidate
        (
              SearchKey
            , SourcePriority
            , TlfsDate
        );

    /*
    主回溯鍵：SFV -> RVU -> RVA -> INA
    */
    ;WITH Ranked AS
    (
        SELECT
              c.*
            , ROW_NUMBER() OVER
              (
                  PARTITION BY c.SearchKey
                  ORDER BY
                        c.SourcePriority
                      , c.TlfsDate DESC
                      , c.PersonId
              ) AS rn
        FROM #PersonCandidate AS c
    )
    SELECT
          SearchKey
        , PersonId
        , PersonName
        , SourcePath
    INTO #PrimaryBest
    FROM Ranked
    WHERE rn = 1;

    CREATE UNIQUE CLUSTERED INDEX IX_PrimaryBest
        ON #PrimaryBest(SearchKey);

    /*
    來源單號備援：SFV -> RVU -> INA
    */
    ;WITH Ranked AS
    (
        SELECT
              c.*
            , ROW_NUMBER() OVER
              (
                  PARTITION BY c.SearchKey
                  ORDER BY
                        c.SourcePriority
                      , c.TlfsDate DESC
                      , c.PersonId
              ) AS rn
        FROM #PersonCandidate AS c
        WHERE c.AllowFallback = 1
    )
    SELECT
          SearchKey
        , PersonId
        , PersonName
        , SourcePath
    INTO #FallbackBest
    FROM Ranked
    WHERE rn = 1;

    CREATE UNIQUE CLUSTERED INDEX IX_FallbackBest
        ON #FallbackBest(SearchKey);

    /*
    ===========================================================================
    6. 一次回寫 Snapshot，只更新找到人員的資料
    ===========================================================================
    */
    DECLARE @UpdatedRows INT;

    UPDATE s
       SET s.sfu16 =
               COALESCE(p.PersonId, f.PersonId),
           s.sfu16_desc =
               COALESCE(p.PersonName, f.PersonName)
    FROM dbo.InventoryInquirySnapshot AS s
    INNER JOIN #Resolved AS r
        ON r.InventoryKey = s.InventoryKey
    LEFT JOIN #PrimaryBest AS p
        ON p.SearchKey = r.ResolvedKey
    LEFT JOIN #FallbackBest AS f
        ON f.SearchKey = r.SourceOrder
    WHERE s.OperatingCenter = N'M302'
      AND COALESCE(p.PersonId, f.PersonId) IS NOT NULL
      AND
      (
          @OnlyMissing = 0
          OR NULLIF(LTRIM(RTRIM(CONVERT(NVARCHAR(100), s.sfu16))), N'')
             IS NULL
      );

    SET @UpdatedRows = @@ROWCOUNT;

    /*
    ===========================================================================
    7. 執行結果
    ===========================================================================
    */
    SELECT
          @AsOfDate AS [計算截止日]
        , (SELECT COUNT(*) FROM #Work) AS [本次處理筆數]
        , @UpdatedRows AS [更新筆數]
        , SUM
          (
              CASE
                  WHEN COALESCE(p.PersonId, f.PersonId) IS NULL
                  THEN 1 ELSE 0
              END
          ) AS [仍無人員筆數]
    FROM #Resolved AS r
    LEFT JOIN #PrimaryBest AS p
        ON p.SearchKey = r.ResolvedKey
    LEFT JOIN #FallbackBest AS f
        ON f.SearchKey = r.SourceOrder;

    SELECT
          COALESCE(p.SourcePath, CONCAT(f.SourcePath, N'-來源單號'))
              AS [人員來源]
        , COUNT(*) AS [筆數]
    FROM #Resolved AS r
    LEFT JOIN #PrimaryBest AS p
        ON p.SearchKey = r.ResolvedKey
    LEFT JOIN #FallbackBest AS f
        ON f.SearchKey = r.SourceOrder
    WHERE COALESCE(p.PersonId, f.PersonId) IS NOT NULL
    GROUP BY
        COALESCE(p.SourcePath, CONCAT(f.SourcePath, N'-來源單號'))
    ORDER BY [人員來源];
END;



GO
