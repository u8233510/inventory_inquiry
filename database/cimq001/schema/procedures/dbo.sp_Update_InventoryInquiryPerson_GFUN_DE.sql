USE [SAL_MRT];
GO



CREATE   PROCEDURE dbo.sp_Update_InventoryInquiryPerson_GFUN_DE
(
      @AsOfDate    DATE = NULL
    , @OnlyMissing BIT  = 1
    , @MaxRows     INT  = NULL
)
AS
BEGIN
    /*
      GFUN D/E 版本：依 cimq001a.4gl。
      重要差異：
        1. 僅處理 ta_ima01 IN ('D','E')。
        2. ERP_Staging 使用非 snx_ 前綴資料表。
        3. Oracle 使用 gfn_202210.tlfs_file。
        4. 顏色/調撥回溯的時間欄位使用 tlfs111，而非興采的 tlfs12。
      不修改任何既有 TABLE；僅更新 InventoryInquirySnapshot.sfu16 / sfu16_desc。
    */
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    /* 診斷計時：不改任何商業邏輯，只量測各段耗時 */
    DECLARE
          @PerfStart           DATETIME2(3) = SYSDATETIME()
        , @StageStart          DATETIME2(3)
        , @CallStart           DATETIME2(3)
        , @ColorStageStart     DATETIME2(3)
        , @PrimaryStageStart   DATETIME2(3)
        , @FallbackStageStart  DATETIME2(3)
        , @ColorOracleMs       BIGINT = 0
        , @ColorTraceMs        BIGINT = 0
        , @PrimaryOracleMs     BIGINT = 0
        , @FallbackOracleMs    BIGINT = 0
        , @ColorOracleCalls    INT = 0
        , @PrimaryOracleCalls  INT = 0
        , @FallbackOracleCalls INT = 0;

    DECLARE @Perf TABLE
    (
          SortNo INT NOT NULL
        , StageName NVARCHAR(100) NOT NULL
        , ElapsedMs BIGINT NOT NULL
        , OracleCalls INT NULL
    );

    IF @MaxRows IS NOT NULL AND @MaxRows <= 0
        THROW 50301, N'@MaxRows 必須為 NULL 或大於 0。', 1;

    IF @AsOfDate IS NULL
    BEGIN
        SELECT @AsOfDate = MAX(a.ActivityDate)
        FROM dbo.InventoryInquiryActivity AS a
        WHERE a.ActivityType = 'TLFS'
          AND a.OperatingCenter = N'GFUN'
          AND EXISTS
          (
              SELECT 1
              FROM dbo.InventoryInquirySnapshot AS s
              WHERE s.InventoryKey = a.InventoryKey
                AND s.OperatingCenter = N'GFUN'
                AND s.ta_ima01 IN (N'D', N'E')
          );
    END;

    IF @AsOfDate IS NULL
        SET @AsOfDate = CONVERT(DATE, GETDATE());

    IF NOT EXISTS (SELECT 1 FROM sys.servers WHERE name = N'ORACLE_LINKED_SERVER')
        THROW 50302, N'缺少 Linked Server：ORACLE_LINKED_SERVER。', 1;

    DROP TABLE IF EXISTS #Work;
    DROP TABLE IF EXISTS #Resolved;
    DROP TABLE IF EXISTS #NextTrace;
    DROP TABLE IF EXISTS #TlfsKey;
    DROP TABLE IF EXISTS #TlfsBatch;
    DROP TABLE IF EXISTS #TlfsCache;
    DROP TABLE IF EXISTS #SearchKey;
    DROP TABLE IF EXISTS #PersonBatch;
    DROP TABLE IF EXISTS #PersonLoaded;
    DROP TABLE IF EXISTS #TlfsPerson;
    DROP TABLE IF EXISTS #PersonCandidate;
    DROP TABLE IF EXISTS #PrimaryBest;
    DROP TABLE IF EXISTS #FallbackBest;

    /* 1. 聚紡 GFUN 資料；只處理 D/E */
    SET @StageStart = SYSDATETIME();

    SELECT TOP (CASE WHEN @MaxRows IS NULL THEN 2147483647 ELSE @MaxRows END)
          s.InventoryKey
        , CONVERT(NVARCHAR(40), s.imgs01) COLLATE Chinese_Taiwan_Stroke_CI_AS AS ItemNo
        , CONVERT(NVARCHAR(40), s.imgs02) COLLATE Chinese_Taiwan_Stroke_CI_AS AS WarehouseNo
        , CONVERT(NVARCHAR(40), s.imgs03) COLLATE Chinese_Taiwan_Stroke_CI_AS AS LocationNo
        , CONVERT(NVARCHAR(40), s.imgs04) COLLATE Chinese_Taiwan_Stroke_CI_AS AS LotOrderNo
        , CONVERT(NVARCHAR(40), s.imgs05) COLLATE Chinese_Taiwan_Stroke_CI_AS AS SerialNo
        , CONVERT(NVARCHAR(40), s.imgs06) COLLATE Chinese_Taiwan_Stroke_CI_AS AS ManufacturingLot
        , NULLIF(LTRIM(RTRIM(CONVERT(NVARCHAR(40), s.source_order))), N'')
              COLLATE Chinese_Taiwan_Stroke_CI_AS AS SourceOrder
    INTO #Work
    FROM dbo.InventoryInquirySnapshot AS s
    WHERE s.OperatingCenter = N'GFUN'
      AND ISNULL(UPPER(LTRIM(RTRIM(CONVERT(NVARCHAR(100), s.ta_ima01)))), N'') IN (N'D', N'E')
      AND
      (
            @OnlyMissing = 0
         OR NULLIF(LTRIM(RTRIM(CONVERT(NVARCHAR(100), s.sfu16))), N'') IS NULL
         OR NULLIF(LTRIM(RTRIM(CONVERT(NVARCHAR(500), s.sfu16_desc))), N'') IS NULL
      )
    ORDER BY s.InventoryKey;

    CREATE UNIQUE CLUSTERED INDEX IX_Work ON #Work(InventoryKey);

    INSERT INTO @Perf(SortNo,StageName,ElapsedMs,OracleCalls)
    VALUES(10,N'01 Snapshot 取待處理資料',DATEDIFF_BIG(MILLISECOND,@StageStart,SYSDATETIME()),NULL);

    IF NOT EXISTS (SELECT 1 FROM #Work)
    BEGIN
        SELECT @AsOfDate AS [計算截止日], 0 AS [本次處理筆數], 0 AS [更新筆數], 0 AS [仍無人員筆數];
        RETURN;
    END;

    SET @StageStart = SYSDATETIME();

    SELECT
          w.InventoryKey
        , w.ItemNo
        , w.WarehouseNo
        , w.LocationNo
        , w.LotOrderNo
        , w.SerialNo
        , w.ManufacturingLot
        , w.SourceOrder
        , CASE WHEN EXISTS
          (
              SELECT 1
              FROM ERP_Staging.dbo.agd_file AS a
              WHERE a.agd02 = w.ManufacturingLot
          ) THEN CONVERT(BIT,1) ELSE CONVERT(BIT,0) END AS IsColor
        , w.WarehouseNo      AS CurrentWarehouse
        , w.LocationNo       AS CurrentLocation
        , w.LotOrderNo       AS CurrentLotOrder
        , w.SerialNo         AS CurrentSerial
        , w.ManufacturingLot AS ResolvedKey
        , CONVERT(BIT,0)     AS TraceDone
    INTO #Resolved
    FROM #Work AS w;

    CREATE UNIQUE CLUSTERED INDEX IX_Resolved ON #Resolved(InventoryKey);
    CREATE INDEX IX_Resolved_Key ON #Resolved(ResolvedKey);

    INSERT INTO @Perf(SortNo,StageName,ElapsedMs,OracleCalls)
    VALUES(20,N'02 初始批號與顏色判斷',DATEDIFF_BIG(MILLISECOND,@StageStart,SYSDATETIME()),NULL);

    /* 2. 一般製造批號：q001_get_tc_imgb07，最多 30 次 */
    SET @StageStart = SYSDATETIME();

    DECLARE @Loop INT = 0, @Changed INT = 1;

    WHILE @Loop < 30 AND @Changed > 0
    BEGIN
        SET @Loop += 1;
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
                  CONVERT(NVARCHAR(40), b.tc_imgb07) COLLATE Chinese_Taiwan_Stroke_CI_AS AS PrevLot
                , CONVERT(NVARCHAR(40), b.tc_imgb03) COLLATE Chinese_Taiwan_Stroke_CI_AS AS PrevWarehouse
                , CONVERT(NVARCHAR(40), b.tc_imgb04) COLLATE Chinese_Taiwan_Stroke_CI_AS AS PrevLocation
                , CONVERT(NVARCHAR(40), b.tc_imgb05) COLLATE Chinese_Taiwan_Stroke_CI_AS AS PrevLotOrder
            FROM ERP_Staging.dbo.tc_imga_file AS a
            INNER JOIN ERP_Staging.dbo.tc_img_file AS h
                ON h.tc_img01 = a.tc_imga01
               AND h.tc_imgconf = N'Y'
            INNER JOIN ERP_Staging.dbo.tc_imgb_file AS b
                ON b.tc_imgb01 = h.tc_img01
               AND b.tc_imgb31 = a.tc_imga31
            WHERE a.tc_imga19 = r.ResolvedKey
              AND h.tc_img03 = r.ItemNo
              AND ISNULL(a.tc_imga05, N'') = ISNULL(r.CurrentLotOrder, N'')
              AND NULLIF(LTRIM(RTRIM(CONVERT(NVARCHAR(40), b.tc_imgb07))), N'') IS NOT NULL
            ORDER BY b.tc_imgb07, b.tc_imgb31
        ) AS x
        WHERE r.IsColor = 0
          AND r.TraceDone = 0;

        CREATE UNIQUE CLUSTERED INDEX IX_NextTrace ON #NextTrace(InventoryKey);

        UPDATE r
           SET r.ResolvedKey = n.PrevLot,
               r.CurrentWarehouse = n.PrevWarehouse,
               r.CurrentLocation = n.PrevLocation,
               r.CurrentLotOrder = n.PrevLotOrder
        FROM #Resolved AS r
        INNER JOIN #NextTrace AS n ON n.InventoryKey = r.InventoryKey
        WHERE n.PrevLot IS NOT NULL
          AND n.PrevLot <> r.ResolvedKey;

        SET @Changed = @@ROWCOUNT;

        UPDATE r
           SET TraceDone = 1
        FROM #Resolved AS r
        INNER JOIN #NextTrace AS n ON n.InventoryKey = r.InventoryKey
        WHERE n.PrevLot IS NULL OR n.PrevLot = r.ResolvedKey;
    END;

    UPDATE #Resolved SET TraceDone = 1 WHERE IsColor = 0;

    INSERT INTO @Perf(SortNo,StageName,ElapsedMs,OracleCalls)
    VALUES(30,N'03 一般製造批號 tc_img 回溯',DATEDIFF_BIG(MILLISECOND,@StageStart,SYSDATETIME()),NULL);

    /* 3. 顏色回溯：Oracle 只讀 TLFS_FILE，且 Cursor 內不連 Oracle */
    SET @ColorStageStart = SYSDATETIME();

    /* 3A. 顏色 TLFS cache
       4GL q001_get_tlfs_p 是用完整庫存鍵：
       tlfs01/02/03/04/05/06 + tlfs09 + tlfs111。
       不可只用 tlfs06，否則 Oracle 會把相同製造批號在其他料號/倉/儲/批序/序號的歷史一起掃回來。
    */
    CREATE TABLE #TlfsKey
    (
          KeyId INT IDENTITY(1,1) NOT NULL PRIMARY KEY
        , ItemNo      NVARCHAR(40) COLLATE Chinese_Taiwan_Stroke_CI_AS NULL
        , WarehouseNo NVARCHAR(40) COLLATE Chinese_Taiwan_Stroke_CI_AS NULL
        , LocationNo  NVARCHAR(40) COLLATE Chinese_Taiwan_Stroke_CI_AS NULL
        , LotOrderNo  NVARCHAR(40) COLLATE Chinese_Taiwan_Stroke_CI_AS NULL
        , SerialNo    NVARCHAR(40) COLLATE Chinese_Taiwan_Stroke_CI_AS NULL
        , SearchKey   NVARCHAR(40) COLLATE Chinese_Taiwan_Stroke_CI_AS NOT NULL
        , Loaded BIT NOT NULL DEFAULT(0)
    );

    CREATE INDEX IX_TlfsKey_State
        ON #TlfsKey(ItemNo,WarehouseNo,LocationNo,LotOrderNo,SerialNo,SearchKey,Loaded);

    CREATE TABLE #TlfsBatch
    (
        KeyId INT NOT NULL PRIMARY KEY
    );

    CREATE TABLE #TlfsCache
    (
          tlfs01  NVARCHAR(40)  COLLATE Chinese_Taiwan_Stroke_CI_AS NULL
        , tlfs02  NVARCHAR(40)  COLLATE Chinese_Taiwan_Stroke_CI_AS NULL
        , tlfs03  NVARCHAR(40)  COLLATE Chinese_Taiwan_Stroke_CI_AS NULL
        , tlfs04  NVARCHAR(40)  COLLATE Chinese_Taiwan_Stroke_CI_AS NULL
        , tlfs05  NVARCHAR(40)  COLLATE Chinese_Taiwan_Stroke_CI_AS NULL
        , tlfs06  NVARCHAR(40)  COLLATE Chinese_Taiwan_Stroke_CI_AS NULL
        , tlfs08  NVARCHAR(100) COLLATE Chinese_Taiwan_Stroke_CI_AS NULL
        , tlfs10  NVARCHAR(40)  COLLATE Chinese_Taiwan_Stroke_CI_AS NULL
        , tlfs11  DECIMAL(18,0) NULL
        , tlfs12  DATETIME2(0)  NULL
        , tlfs111 DATETIME2(0)  NULL
    );

    CREATE INDEX IX_TlfsCache
        ON #TlfsCache(tlfs01,tlfs02,tlfs03,tlfs04,tlfs05,tlfs06,tlfs111)
        INCLUDE(tlfs08,tlfs10,tlfs11,tlfs12);

    INSERT INTO #TlfsKey(ItemNo,WarehouseNo,LocationNo,LotOrderNo,SerialNo,SearchKey,Loaded)
    SELECT DISTINCT
          ItemNo
        , CurrentWarehouse
        , CurrentLocation
        , CurrentLotOrder
        , CurrentSerial
        , ResolvedKey
        , 0
    FROM #Resolved
    WHERE IsColor = 1
      AND NULLIF(LTRIM(RTRIM(ResolvedKey)), N'') IS NOT NULL;

    DECLARE
          @OracleList   NVARCHAR(MAX)
        , @OracleQuery  NVARCHAR(MAX)
        , @ExecSql      NVARCHAR(MAX)
        , @EscapedOracle NVARCHAR(MAX)
        , @OracleCutoff CHAR(10) = CONVERT(CHAR(10), DATEADD(DAY,1,@AsOfDate),120)
        , @ColorRound   INT = 0;

    WHILE EXISTS (SELECT 1 FROM #Resolved WHERE IsColor=1 AND TraceDone=0)
      AND @ColorRound < 20
    BEGIN
        SET @ColorRound += 1;

        WHILE EXISTS (SELECT 1 FROM #TlfsKey WHERE Loaded=0)
        BEGIN
            TRUNCATE TABLE #TlfsBatch;

            ;WITH P AS
            (
                SELECT
                      k.KeyId
                    , CONVERT(NVARCHAR(MAX),
                        N'(tlfs01=''' + REPLACE(ISNULL(k.ItemNo,N''),N'''',N'''''') + N''''
                      + CASE WHEN NULLIF(k.WarehouseNo,N'') IS NULL
                             THEN N' AND tlfs02 IS NULL'
                             ELSE N' AND tlfs02=''' + REPLACE(k.WarehouseNo,N'''',N'''''') + N'''' END
                      + CASE WHEN NULLIF(k.LocationNo,N'') IS NULL
                             THEN N' AND tlfs03 IS NULL'
                             ELSE N' AND tlfs03=''' + REPLACE(k.LocationNo,N'''',N'''''') + N'''' END
                      + CASE WHEN NULLIF(k.LotOrderNo,N'') IS NULL
                             THEN N' AND tlfs04 IS NULL'
                             ELSE N' AND tlfs04=''' + REPLACE(k.LotOrderNo,N'''',N'''''') + N'''' END
                      + CASE WHEN NULLIF(k.SerialNo,N'') IS NULL
                             THEN N' AND tlfs05 IS NULL'
                             ELSE N' AND tlfs05=''' + REPLACE(k.SerialNo,N'''',N'''''') + N'''' END
                      + N' AND tlfs06=''' + REPLACE(k.SearchKey,N'''',N'''''') + N''')'
                      ) AS PredText
                FROM #TlfsKey AS k
                WHERE k.Loaded=0
            ), R AS
            (
                SELECT
                      KeyId
                    , PredText
                    , SUM(LEN(PredText)+4) OVER (ORDER BY KeyId ROWS UNBOUNDED PRECEDING) AS RunningChars
                FROM P
            )
            INSERT INTO #TlfsBatch(KeyId)
            SELECT KeyId
            FROM R
            WHERE RunningChars <= 4800;

            IF NOT EXISTS (SELECT 1 FROM #TlfsBatch)
            BEGIN
                INSERT INTO #TlfsBatch(KeyId)
                SELECT TOP (1) KeyId
                FROM #TlfsKey
                WHERE Loaded=0
                ORDER BY KeyId;
            END;

            SELECT @OracleList =
                STRING_AGG
                (
                    CONVERT(NVARCHAR(MAX),
                        N'(tlfs01=''' + REPLACE(ISNULL(k.ItemNo,N''),N'''',N'''''') + N''''
                      + CASE WHEN NULLIF(k.WarehouseNo,N'') IS NULL
                             THEN N' AND tlfs02 IS NULL'
                             ELSE N' AND tlfs02=''' + REPLACE(k.WarehouseNo,N'''',N'''''') + N'''' END
                      + CASE WHEN NULLIF(k.LocationNo,N'') IS NULL
                             THEN N' AND tlfs03 IS NULL'
                             ELSE N' AND tlfs03=''' + REPLACE(k.LocationNo,N'''',N'''''') + N'''' END
                      + CASE WHEN NULLIF(k.LotOrderNo,N'') IS NULL
                             THEN N' AND tlfs04 IS NULL'
                             ELSE N' AND tlfs04=''' + REPLACE(k.LotOrderNo,N'''',N'''''') + N'''' END
                      + CASE WHEN NULLIF(k.SerialNo,N'') IS NULL
                             THEN N' AND tlfs05 IS NULL'
                             ELSE N' AND tlfs05=''' + REPLACE(k.SerialNo,N'''',N'''''') + N'''' END
                      + N' AND tlfs06=''' + REPLACE(k.SearchKey,N'''',N'''''') + N''')'
                    ),
                    N' OR '
                )
            FROM #TlfsKey AS k
            INNER JOIN #TlfsBatch AS b
                ON b.KeyId=k.KeyId;

            SET @OracleQuery =
                  N'SELECT RTRIM(tlfs01) tlfs01,RTRIM(tlfs02) tlfs02,RTRIM(tlfs03) tlfs03,'
                + N'RTRIM(tlfs04) tlfs04,RTRIM(tlfs05) tlfs05,RTRIM(tlfs06) tlfs06,'
                + N'RTRIM(tlfs08) tlfs08,RTRIM(tlfs10) tlfs10,tlfs11,'
                + N'TO_CHAR(tlfs12,''YYYY-MM-DD HH24:MI:SS'') tlfs12,'
                + N'TO_CHAR(tlfs111,''YYYY-MM-DD HH24:MI:SS'') tlfs111 '
                + N'FROM gfn_202210.tlfs_file '
                + N'WHERE tlfs09=1 '
                + N'AND tlfs111 < TO_DATE(''' + @OracleCutoff + N''',''YYYY-MM-DD'') '
                + N'AND (' + @OracleList + N')';

            SET @EscapedOracle = REPLACE(@OracleQuery, NCHAR(39), NCHAR(39)+NCHAR(39));
            IF LEN(@EscapedOracle) > 7400
                THROW 50310, N'顏色 TLFS Oracle 查詢超過 OPENQUERY 安全長度。', 1;

            SET @ExecSql =
                  N'INSERT INTO #TlfsCache(tlfs01,tlfs02,tlfs03,tlfs04,tlfs05,tlfs06,tlfs08,tlfs10,tlfs11,tlfs12,tlfs111) '
                + N'SELECT CONVERT(NVARCHAR(40),q.tlfs01),CONVERT(NVARCHAR(40),q.tlfs02),'
                + N'CONVERT(NVARCHAR(40),q.tlfs03),CONVERT(NVARCHAR(40),q.tlfs04),'
                + N'CONVERT(NVARCHAR(40),q.tlfs05),CONVERT(NVARCHAR(40),q.tlfs06),'
                + N'CONVERT(NVARCHAR(100),q.tlfs08),CONVERT(NVARCHAR(40),q.tlfs10),'
                + N'TRY_CONVERT(DECIMAL(18,0),q.tlfs11),TRY_CONVERT(DATETIME2(0),q.tlfs12),'
                + N'TRY_CONVERT(DATETIME2(0),q.tlfs111) '
                + N'FROM OPENQUERY([ORACLE_LINKED_SERVER],'''
                + @EscapedOracle + N''') AS q;';

            SET @CallStart = SYSDATETIME();
            EXEC sys.sp_executesql @ExecSql;
            SET @ColorOracleMs += DATEDIFF_BIG(MILLISECOND,@CallStart,SYSDATETIME());
            SET @ColorOracleCalls += 1;

            UPDATE k
               SET Loaded=1
            FROM #TlfsKey AS k
            INNER JOIN #TlfsBatch AS b
                ON b.KeyId=k.KeyId;
        END;

        DECLARE
              @InventoryKey VARBINARY(32)
            , @ItemNo NVARCHAR(40)
            , @CurrentWarehouse NVARCHAR(40)
            , @CurrentLocation NVARCHAR(40)
            , @CurrentLotOrder NVARCHAR(40)
            , @CurrentSerial NVARCHAR(40)
            , @ResolvedKey NVARCHAR(40)
            , @CurrentIsColor BIT
            , @RowDone BIT
            , @NeedLoad BIT
            , @Outer INT
            , @Inner INT
            , @Transfer INT
            , @Found BIT
            , @Tlfs02 NVARCHAR(40)
            , @Tlfs03 NVARCHAR(40)
            , @Tlfs04 NVARCHAR(40)
            , @Tlfs05 NVARCHAR(40)
            , @Tlfs06 NVARCHAR(40)
            , @Tlfs08 NVARCHAR(100)
            , @Tlfs10 NVARCHAR(40)
            , @Tlfs11 DECIMAL(18,0)
            , @Tlfs12 DATETIME2(0)
            , @Tlfs111 DATETIME2(0)
            , @LastTlfs10 NVARCHAR(40)
            , @TlfsCutoff DATETIME2(0)
            , @TlfWarehouse NVARCHAR(40)
            , @TlfLocation NVARCHAR(40)
            , @TlfLotOrder NVARCHAR(40)
            , @PrevLot NVARCHAR(40)
            , @PrevWarehouse NVARCHAR(40)
            , @PrevLocation NVARCHAR(40)
            , @PrevLotOrder NVARCHAR(40);

        DECLARE ColorCursor CURSOR LOCAL FAST_FORWARD FOR
        SELECT InventoryKey,ItemNo,CurrentWarehouse,CurrentLocation,CurrentLotOrder,CurrentSerial,ResolvedKey
        FROM #Resolved
        WHERE IsColor=1 AND TraceDone=0
        ORDER BY InventoryKey;

        SET @CallStart = SYSDATETIME();
        OPEN ColorCursor;
        FETCH NEXT FROM ColorCursor INTO
            @InventoryKey,@ItemNo,@CurrentWarehouse,@CurrentLocation,@CurrentLotOrder,@CurrentSerial,@ResolvedKey;

        WHILE @@FETCH_STATUS=0
        BEGIN
            SET @RowDone=0;
            SET @NeedLoad=0;
            SET @Outer=0;

            WHILE @RowDone=0 AND @NeedLoad=0 AND @Outer<20
            BEGIN
                SET @Outer += 1;

                SELECT @CurrentIsColor = CASE WHEN EXISTS
                (
                    SELECT 1 FROM ERP_Staging.dbo.agd_file WHERE agd02=@ResolvedKey
                ) THEN 1 ELSE 0 END;

                IF @CurrentIsColor=0
                BEGIN
                    SET @Transfer=0;
                    WHILE @Transfer<30
                    BEGIN
                        SET @Transfer += 1;
                        SET @PrevLot=NULL;
                        SET @PrevWarehouse=NULL;
                        SET @PrevLocation=NULL;
                        SET @PrevLotOrder=NULL;

                        SELECT TOP (1)
                              @PrevLot=CONVERT(NVARCHAR(40),b.tc_imgb07)
                            , @PrevWarehouse=CONVERT(NVARCHAR(40),b.tc_imgb03)
                            , @PrevLocation=CONVERT(NVARCHAR(40),b.tc_imgb04)
                            , @PrevLotOrder=CONVERT(NVARCHAR(40),b.tc_imgb05)
                        FROM ERP_Staging.dbo.tc_imga_file AS a
                        INNER JOIN ERP_Staging.dbo.tc_img_file AS h
                            ON h.tc_img01=a.tc_imga01 AND h.tc_imgconf=N'Y'
                        INNER JOIN ERP_Staging.dbo.tc_imgb_file AS b
                            ON b.tc_imgb01=h.tc_img01 AND b.tc_imgb31=a.tc_imga31
                        WHERE a.tc_imga19=@ResolvedKey
                          AND h.tc_img03=@ItemNo
                          AND ISNULL(a.tc_imga05,N'')=ISNULL(@CurrentLotOrder,N'')
                        ORDER BY b.tc_imgb07,b.tc_imgb31;

                        IF @PrevLot IS NULL OR @PrevLot=@ResolvedKey BREAK;
                        SET @ResolvedKey=@PrevLot;
                        SET @CurrentWarehouse=@PrevWarehouse;
                        SET @CurrentLocation=@PrevLocation;
                        SET @CurrentLotOrder=@PrevLotOrder;
                    END;

                    SET @RowDone=1;
                    BREAK;
                END;

                IF NOT EXISTS
                (
                    SELECT 1
                    FROM #TlfsKey
                    WHERE ISNULL(ItemNo,N'')=ISNULL(@ItemNo,N'')
                      AND ISNULL(WarehouseNo,N'')=ISNULL(@CurrentWarehouse,N'')
                      AND ISNULL(LocationNo,N'')=ISNULL(@CurrentLocation,N'')
                      AND ISNULL(LotOrderNo,N'')=ISNULL(@CurrentLotOrder,N'')
                      AND ISNULL(SerialNo,N'')=ISNULL(@CurrentSerial,N'')
                      AND SearchKey=@ResolvedKey
                      AND Loaded=1
                )
                BEGIN
                    IF NOT EXISTS
                    (
                        SELECT 1
                        FROM #TlfsKey
                        WHERE ISNULL(ItemNo,N'')=ISNULL(@ItemNo,N'')
                          AND ISNULL(WarehouseNo,N'')=ISNULL(@CurrentWarehouse,N'')
                          AND ISNULL(LocationNo,N'')=ISNULL(@CurrentLocation,N'')
                          AND ISNULL(LotOrderNo,N'')=ISNULL(@CurrentLotOrder,N'')
                          AND ISNULL(SerialNo,N'')=ISNULL(@CurrentSerial,N'')
                          AND SearchKey=@ResolvedKey
                    )
                    BEGIN
                        INSERT INTO #TlfsKey
                        (
                            ItemNo,WarehouseNo,LocationNo,LotOrderNo,SerialNo,SearchKey,Loaded
                        )
                        VALUES
                        (
                            @ItemNo,@CurrentWarehouse,@CurrentLocation,@CurrentLotOrder,@CurrentSerial,@ResolvedKey,0
                        );
                    END;
                    SET @NeedLoad=1;
                    BREAK;
                END;

                SET @LastTlfs10=N'ABCZZZZZZZ';
                SET @TlfsCutoff=DATEADD(SECOND,-1,DATEADD(DAY,1,CONVERT(DATETIME2(0),@AsOfDate)));
                SET @Found=0;
                SET @Inner=0;

                WHILE @Inner<6
                BEGIN
                    SET @Inner += 1;
                    SET @Found=0;
                    SET @Tlfs02=NULL; SET @Tlfs03=NULL; SET @Tlfs04=NULL; SET @Tlfs05=NULL;
                    SET @Tlfs06=NULL; SET @Tlfs08=NULL; SET @Tlfs10=NULL; SET @Tlfs11=NULL;
                    SET @Tlfs12=NULL; SET @Tlfs111=NULL;

                    SELECT TOP (1)
                          @Tlfs02=f.tlfs02,@Tlfs03=f.tlfs03,@Tlfs04=f.tlfs04,@Tlfs05=f.tlfs05
                        , @Tlfs06=f.tlfs06,@Tlfs08=f.tlfs08,@Tlfs10=f.tlfs10,@Tlfs11=f.tlfs11
                        , @Tlfs12=f.tlfs12,@Tlfs111=f.tlfs111,@Found=1
                    FROM #TlfsCache AS f
                    WHERE f.tlfs01=@ItemNo
                      AND f.tlfs02=@CurrentWarehouse
                      AND f.tlfs03=@CurrentLocation
                      AND f.tlfs04=@CurrentLotOrder
                      AND ISNULL(f.tlfs05,N'')=ISNULL(@CurrentSerial,N'')
                      AND f.tlfs06=@ResolvedKey
                      AND f.tlfs10<>@LastTlfs10
                      AND f.tlfs111<=@TlfsCutoff
                    ORDER BY f.tlfs111 DESC;

                    IF @Found=0 BREAK;

                    IF LEFT(ISNULL(@Tlfs08,N''),6) IN (N'aimt32',N'cimt32')
                    BEGIN
                        SET @TlfWarehouse=NULL;
                        SET @TlfLocation=NULL;
                        SET @TlfLotOrder=NULL;

                        SELECT TOP (1)
                              @TlfWarehouse=CONVERT(NVARCHAR(40),tlf902)
                            , @TlfLocation=CONVERT(NVARCHAR(40),tlf903)
                            , @TlfLotOrder=CONVERT(NVARCHAR(40),tlf904)
                        FROM ERP_Staging.dbo.tlf_file
                        WHERE tlf905=@Tlfs10
                          AND tlf906=@Tlfs11
                          AND tlf907=-1;

                        IF @TlfWarehouse IS NULL BREAK;

                        SET @CurrentWarehouse=@TlfWarehouse;
                        SET @CurrentLocation=@TlfLocation;
                        SET @CurrentLotOrder=@TlfLotOrder;
                        SET @CurrentSerial=@Tlfs05;
                        SET @ResolvedKey=@Tlfs06;
                        SET @LastTlfs10=@Tlfs10;
                        SET @TlfsCutoff=@Tlfs111;

                        IF NOT EXISTS
                        (
                            SELECT 1
                            FROM #TlfsKey
                            WHERE ISNULL(ItemNo,N'')=ISNULL(@ItemNo,N'')
                              AND ISNULL(WarehouseNo,N'')=ISNULL(@CurrentWarehouse,N'')
                              AND ISNULL(LocationNo,N'')=ISNULL(@CurrentLocation,N'')
                              AND ISNULL(LotOrderNo,N'')=ISNULL(@CurrentLotOrder,N'')
                              AND ISNULL(SerialNo,N'')=ISNULL(@CurrentSerial,N'')
                              AND SearchKey=@ResolvedKey
                              AND Loaded=1
                        )
                        BEGIN
                            IF NOT EXISTS
                            (
                                SELECT 1
                                FROM #TlfsKey
                                WHERE ISNULL(ItemNo,N'')=ISNULL(@ItemNo,N'')
                                  AND ISNULL(WarehouseNo,N'')=ISNULL(@CurrentWarehouse,N'')
                                  AND ISNULL(LocationNo,N'')=ISNULL(@CurrentLocation,N'')
                                  AND ISNULL(LotOrderNo,N'')=ISNULL(@CurrentLotOrder,N'')
                                  AND ISNULL(SerialNo,N'')=ISNULL(@CurrentSerial,N'')
                                  AND SearchKey=@ResolvedKey
                            )
                            BEGIN
                                INSERT INTO #TlfsKey
                                (
                                    ItemNo,WarehouseNo,LocationNo,LotOrderNo,SerialNo,SearchKey,Loaded
                                )
                                VALUES
                                (
                                    @ItemNo,@CurrentWarehouse,@CurrentLocation,@CurrentLotOrder,@CurrentSerial,@ResolvedKey,0
                                );
                            END;
                            SET @NeedLoad=1;
                            BREAK;
                        END;

                        CONTINUE;
                    END;

                    BREAK;
                END;

                IF @NeedLoad=1
                    BREAK;

                IF @Found=0
                BEGIN
                    SET @RowDone=1;
                    BREAK;
                END;

                IF LEFT(ISNULL(@Tlfs08,N''),6) IN (N'asft62',N'csft62')
                   AND EXISTS
                   (
                       SELECT 1
                       FROM ERP_Staging.dbo.tc_img_file
                       WHERE tc_imgconf=N'Y' AND tc_img08=@Tlfs10
                   )
                BEGIN
                    SET @CurrentWarehouse=@Tlfs02;
                    SET @CurrentLocation=@Tlfs03;
                    SET @CurrentLotOrder=@Tlfs04;
                    SET @CurrentSerial=@Tlfs05;
                    SET @ResolvedKey=@Tlfs06;
                    SET @Transfer=0;

                    WHILE @Transfer<30
                    BEGIN
                        SET @Transfer += 1;
                        SET @PrevLot=NULL;
                        SET @PrevWarehouse=NULL;
                        SET @PrevLocation=NULL;
                        SET @PrevLotOrder=NULL;

                        SELECT TOP (1)
                              @PrevLot=CONVERT(NVARCHAR(40),b.tc_imgb07)
                            , @PrevWarehouse=CONVERT(NVARCHAR(40),b.tc_imgb03)
                            , @PrevLocation=CONVERT(NVARCHAR(40),b.tc_imgb04)
                            , @PrevLotOrder=CONVERT(NVARCHAR(40),b.tc_imgb05)
                        FROM ERP_Staging.dbo.tc_imga_file AS a
                        INNER JOIN ERP_Staging.dbo.tc_img_file AS h
                            ON h.tc_img01=a.tc_imga01 AND h.tc_imgconf=N'Y'
                        INNER JOIN ERP_Staging.dbo.tc_imgb_file AS b
                            ON b.tc_imgb01=h.tc_img01 AND b.tc_imgb31=a.tc_imga31
                        WHERE a.tc_imga19=@ResolvedKey
                          AND h.tc_img03=@ItemNo
                          AND a.tc_imga03=@CurrentWarehouse
                          AND ISNULL(a.tc_imga04,N'')=ISNULL(@CurrentLocation,N'')
                          AND ISNULL(a.tc_imga05,N'')=ISNULL(@CurrentLotOrder,N'')
                          AND EXISTS
                          (
                              SELECT 1
                              FROM ERP_Staging.dbo.sfu_file AS u
                              WHERE u.sfu01=h.tc_img08
                                AND u.sfu02=@Tlfs111
                          )
                        ORDER BY b.tc_imgb07,b.tc_imgb31;

                        IF @PrevLot IS NULL OR @PrevLot=@ResolvedKey BREAK;
                        SET @ResolvedKey=@PrevLot;
                        SET @CurrentWarehouse=@PrevWarehouse;
                        SET @CurrentLocation=@PrevLocation;
                        SET @CurrentLotOrder=@PrevLotOrder;
                    END;

                    CONTINUE;
                END;

                SET @ResolvedKey=@Tlfs10;
                SET @RowDone=1;
            END;

            UPDATE #Resolved
               SET ResolvedKey=@ResolvedKey,
                   CurrentWarehouse=@CurrentWarehouse,
                   CurrentLocation=@CurrentLocation,
                   CurrentLotOrder=@CurrentLotOrder,
                   CurrentSerial=@CurrentSerial,
                   TraceDone=CASE WHEN @NeedLoad=1 THEN 0 ELSE @RowDone END
            WHERE InventoryKey=@InventoryKey;

            FETCH NEXT FROM ColorCursor INTO
                @InventoryKey,@ItemNo,@CurrentWarehouse,@CurrentLocation,@CurrentLotOrder,@CurrentSerial,@ResolvedKey;
        END;

        CLOSE ColorCursor;
        DEALLOCATE ColorCursor;
        SET @ColorTraceMs += DATEDIFF_BIG(MILLISECOND,@CallStart,SYSDATETIME());
    END;

    INSERT INTO @Perf(SortNo,StageName,ElapsedMs,OracleCalls)
    VALUES
          (40,N'04A 顏色 TLFS Oracle',@ColorOracleMs,@ColorOracleCalls)
        , (41,N'04B 顏色回溯 SQL/Cursor',@ColorTraceMs,NULL)
        , (42,N'04C 顏色回溯總計',DATEDIFF_BIG(MILLISECOND,@ColorStageStart,SYSDATETIME()),NULL);

    IF EXISTS (SELECT 1 FROM #Resolved WHERE IsColor=1 AND TraceDone=0)
        THROW 50311, N'顏色製造批號回溯超過 20 輪，已中止避免無限迴圈。', 1;

    /* 4. 人員查找（FAST）
       先查 ResolvedKey；只有 Primary 找不到的人，才查 SourceOrder fallback。
       Oracle 仍只讀 GFN_202210.TLFS_FILE，不修改任何既有 TABLE / SP / Linked Server 設定。
    */

    DROP TABLE IF EXISTS #PrimarySearchKey;
    DROP TABLE IF EXISTS #PrimaryBatch;
    DROP TABLE IF EXISTS #PrimaryLoaded;
    DROP TABLE IF EXISTS #TlfsPerson;
    DROP TABLE IF EXISTS #PersonCandidate;
    DROP TABLE IF EXISTS #PrimaryBest;
    DROP TABLE IF EXISTS #FallbackSearchKey;
    DROP TABLE IF EXISTS #FallbackBatch;
    DROP TABLE IF EXISTS #FallbackLoaded;
    DROP TABLE IF EXISTS #TlfsFallback;
    DROP TABLE IF EXISTS #FallbackCandidate;
    DROP TABLE IF EXISTS #FallbackBest;

    /* 4-1. Primary：只查回溯後 ResolvedKey */
    SET @PrimaryStageStart = SYSDATETIME();

    SELECT DISTINCT
           NULLIF(LTRIM(RTRIM(ResolvedKey)),N'') AS SearchKey
    INTO #PrimarySearchKey
    FROM #Resolved
    WHERE NULLIF(LTRIM(RTRIM(ResolvedKey)),N'') IS NOT NULL;

    CREATE UNIQUE CLUSTERED INDEX IX_PrimarySearchKey ON #PrimarySearchKey(SearchKey);

    CREATE TABLE #PrimaryBatch
    (
        SearchKey NVARCHAR(40) COLLATE Chinese_Taiwan_Stroke_CI_AS NOT NULL PRIMARY KEY
    );

    CREATE TABLE #PrimaryLoaded
    (
        SearchKey NVARCHAR(40) COLLATE Chinese_Taiwan_Stroke_CI_AS NOT NULL PRIMARY KEY
    );

    CREATE TABLE #TlfsPerson
    (
          tlfs06 NVARCHAR(40) COLLATE Chinese_Taiwan_Stroke_CI_AS NOT NULL
        , tlfs10 NVARCHAR(40) COLLATE Chinese_Taiwan_Stroke_CI_AS NULL
        , tlfs11 DECIMAL(18,0) NULL
        , tlfs12 DATETIME2(0) NULL
    );

    WHILE EXISTS
    (
        SELECT 1
        FROM #PrimarySearchKey AS k
        WHERE NOT EXISTS
        (
            SELECT 1
            FROM #PrimaryLoaded AS d
            WHERE d.SearchKey=k.SearchKey
        )
    )
    BEGIN
        TRUNCATE TABLE #PrimaryBatch;

        ;WITH P AS
        (
            SELECT k.SearchKey,
                   LEN(N'''' + REPLACE(k.SearchKey,N'''',N'''''') + N''',') AS KeyChars
            FROM #PrimarySearchKey AS k
            WHERE NOT EXISTS
            (
                SELECT 1
                FROM #PrimaryLoaded AS d
                WHERE d.SearchKey=k.SearchKey
            )
        ), R AS
        (
            SELECT SearchKey,
                   SUM(KeyChars) OVER
                   (ORDER BY SearchKey ROWS UNBOUNDED PRECEDING) AS RunningChars
            FROM P
        )
        INSERT INTO #PrimaryBatch(SearchKey)
        SELECT SearchKey
        FROM R
        WHERE RunningChars <= 5000;

        IF NOT EXISTS (SELECT 1 FROM #PrimaryBatch)
        BEGIN
            INSERT INTO #PrimaryBatch(SearchKey)
            SELECT TOP (1) k.SearchKey
            FROM #PrimarySearchKey AS k
            WHERE NOT EXISTS
            (
                SELECT 1
                FROM #PrimaryLoaded AS d
                WHERE d.SearchKey=k.SearchKey
            )
            ORDER BY k.SearchKey;
        END;

        SELECT @OracleList=STRING_AGG
        (
            CONVERT(NVARCHAR(MAX),N'''' + REPLACE(SearchKey,N'''',N'''''') + N''''),
            N','
        )
        FROM #PrimaryBatch;

        SET @OracleQuery=
              N'SELECT RTRIM(tlfs06) tlfs06,RTRIM(tlfs10) tlfs10,tlfs11,'
            + N'TO_CHAR(MAX(tlfs111),''YYYY-MM-DD HH24:MI:SS'') tlfs12 '
            + N'FROM gfn_202210.tlfs_file '
            + N'WHERE tlfs06 IN (' + @OracleList + N') '
            + N'AND tlfs10 IS NOT NULL '
            + N'GROUP BY tlfs06,tlfs10,tlfs11';

        SET @EscapedOracle=REPLACE(@OracleQuery,NCHAR(39),NCHAR(39)+NCHAR(39));
        IF LEN(@EscapedOracle)>7400
            THROW 50312, N'Primary TLFS Oracle 查詢超過 OPENQUERY 安全長度。', 1;

        SET @ExecSql=
              N'INSERT INTO #TlfsPerson(tlfs06,tlfs10,tlfs11,tlfs12) '
            + N'SELECT CONVERT(NVARCHAR(40),q.tlfs06),CONVERT(NVARCHAR(40),q.tlfs10),'
            + N'TRY_CONVERT(DECIMAL(18,0),q.tlfs11),TRY_CONVERT(DATETIME2(0),q.tlfs12) '
            + N'FROM OPENQUERY([ORACLE_LINKED_SERVER],'''
            + @EscapedOracle + N''') AS q;';

        SET @CallStart = SYSDATETIME();
        EXEC sys.sp_executesql @ExecSql;
        SET @PrimaryOracleMs += DATEDIFF_BIG(MILLISECOND,@CallStart,SYSDATETIME());
        SET @PrimaryOracleCalls += 1;

        INSERT INTO #PrimaryLoaded(SearchKey)
        SELECT SearchKey
        FROM #PrimaryBatch;
    END;

    CREATE INDEX IX_TlfsPerson
        ON #TlfsPerson(tlfs06,tlfs10,tlfs11)
        INCLUDE(tlfs12);

    CREATE TABLE #PersonCandidate
    (
          SearchKey NVARCHAR(40) COLLATE Chinese_Taiwan_Stroke_CI_AS NOT NULL
        , SourcePriority TINYINT NOT NULL
        , PersonId NVARCHAR(40) NULL
        , PersonName NVARCHAR(100) NULL
        , TlfsDate DATETIME2(0) NULL
    );

    /* SFV -> SFB.sfb44 */
    INSERT INTO #PersonCandidate(SearchKey,SourcePriority,PersonId,PersonName,TlfsDate)
    SELECT
          t.tlfs06,1
        , NULLIF(LTRIM(RTRIM(CONVERT(NVARCHAR(40),sfb.sfb44))),N'')
        , NULLIF(LTRIM(RTRIM(CONVERT(NVARCHAR(100),gen.gen02))),N'')
        , t.tlfs12
    FROM #TlfsPerson AS t
    INNER JOIN ERP_Staging.dbo.sfv_file AS sfv
        ON sfv.sfv01=t.tlfs10 AND sfv.sfv03=t.tlfs11
    INNER JOIN ERP_Staging.dbo.sfb_file AS sfb
        ON sfb.sfb01=sfv.sfv11
    LEFT JOIN ERP_Staging.dbo.gen_file AS gen
        ON gen.gen01=sfb.sfb44
    WHERE NULLIF(LTRIM(RTRIM(CONVERT(NVARCHAR(40),sfb.sfb44))),N'') IS NOT NULL;

    /* RVV -> RVU.rvu07 */
    INSERT INTO #PersonCandidate(SearchKey,SourcePriority,PersonId,PersonName,TlfsDate)
    SELECT
          t.tlfs06,2
        , NULLIF(LTRIM(RTRIM(CONVERT(NVARCHAR(40),rvu.rvu07))),N'')
        , NULLIF(LTRIM(RTRIM(CONVERT(NVARCHAR(100),gen.gen02))),N'')
        , t.tlfs12
    FROM #TlfsPerson AS t
    INNER JOIN ERP_Staging.dbo.rvv_file AS rvv
        ON rvv.rvv01=t.tlfs10 AND rvv.rvv02=t.tlfs11
    INNER JOIN ERP_Staging.dbo.rvu_file AS rvu
        ON rvu.rvu01=rvv.rvv01
       AND rvu.rvu00=N'1'
       AND rvu.rvuconf=N'Y'
    LEFT JOIN ERP_Staging.dbo.gen_file AS gen
        ON gen.gen01=rvu.rvu07
    WHERE NULLIF(LTRIM(RTRIM(CONVERT(NVARCHAR(40),rvu.rvu07))),N'') IS NOT NULL;

    /* RVA.rva33 */
    INSERT INTO #PersonCandidate(SearchKey,SourcePriority,PersonId,PersonName,TlfsDate)
    SELECT
          t.tlfs06,3
        , NULLIF(LTRIM(RTRIM(CONVERT(NVARCHAR(40),rva.rva33))),N'')
        , NULLIF(LTRIM(RTRIM(CONVERT(NVARCHAR(100),gen.gen02))),N'')
        , t.tlfs12
    FROM #TlfsPerson AS t
    INNER JOIN ERP_Staging.dbo.rva_file AS rva
        ON rva.rva01=t.tlfs10
       AND rva.rvaconf=N'Y'
    LEFT JOIN ERP_Staging.dbo.gen_file AS gen
        ON gen.gen01=rva.rva33
    WHERE NULLIF(LTRIM(RTRIM(CONVERT(NVARCHAR(40),rva.rva33))),N'') IS NOT NULL;

    /* INA.ina11 */
    INSERT INTO #PersonCandidate(SearchKey,SourcePriority,PersonId,PersonName,TlfsDate)
    SELECT
          t.tlfs06,4
        , NULLIF(LTRIM(RTRIM(CONVERT(NVARCHAR(40),ina.ina11))),N'')
        , NULLIF(LTRIM(RTRIM(CONVERT(NVARCHAR(100),gen.gen02))),N'')
        , t.tlfs12
    FROM #TlfsPerson AS t
    INNER JOIN ERP_Staging.dbo.ina_file AS ina
        ON ina.ina01=t.tlfs10
       AND ina.inaconf=N'Y'
       AND ina.inapost=N'Y'
       AND ina.ina00 IN (N'2',N'4')
    LEFT JOIN ERP_Staging.dbo.gen_file AS gen
        ON gen.gen01=ina.ina11
    WHERE NULLIF(LTRIM(RTRIM(CONVERT(NVARCHAR(40),ina.ina11))),N'') IS NOT NULL;

    CREATE TABLE #PrimaryBest
    (
          SearchKey NVARCHAR(40) COLLATE Chinese_Taiwan_Stroke_CI_AS NOT NULL PRIMARY KEY
        , PersonId NVARCHAR(40) NULL
        , PersonName NVARCHAR(100) NULL
        , SourcePriority TINYINT NOT NULL
    );

    ;WITH R AS
    (
        SELECT SearchKey,PersonId,PersonName,SourcePriority,TlfsDate,
               ROW_NUMBER() OVER
               (
                   PARTITION BY SearchKey
                   ORDER BY SourcePriority,TlfsDate DESC
               ) AS rn
        FROM #PersonCandidate
        WHERE PersonId IS NOT NULL
    )
    INSERT INTO #PrimaryBest(SearchKey,PersonId,PersonName,SourcePriority)
    SELECT SearchKey,PersonId,PersonName,SourcePriority
    FROM R
    WHERE rn=1;

    INSERT INTO @Perf(SortNo,StageName,ElapsedMs,OracleCalls)
    VALUES
          (50,N'05A Primary TLFS Oracle',@PrimaryOracleMs,@PrimaryOracleCalls)
        , (51,N'05B Primary 本機人員判斷',
              DATEDIFF_BIG(MILLISECOND,@PrimaryStageStart,SYSDATETIME())-@PrimaryOracleMs,NULL)
        , (52,N'05C Primary 總計',
              DATEDIFF_BIG(MILLISECOND,@PrimaryStageStart,SYSDATETIME()),NULL);

    /* 4-2. Fallback：只有 Primary 沒找到的人才查 SourceOrder */
    SET @FallbackStageStart = SYSDATETIME();

    SELECT DISTINCT
           NULLIF(LTRIM(RTRIM(r.SourceOrder)),N'') AS SearchKey
    INTO #FallbackSearchKey
    FROM #Resolved AS r
    LEFT JOIN #PrimaryBest AS p
        ON p.SearchKey=r.ResolvedKey
    WHERE p.PersonId IS NULL
      AND NULLIF(LTRIM(RTRIM(r.SourceOrder)),N'') IS NOT NULL;

    CREATE UNIQUE CLUSTERED INDEX IX_FallbackSearchKey ON #FallbackSearchKey(SearchKey);

    CREATE TABLE #FallbackBatch
    (
        SearchKey NVARCHAR(40) COLLATE Chinese_Taiwan_Stroke_CI_AS NOT NULL PRIMARY KEY
    );

    CREATE TABLE #FallbackLoaded
    (
        SearchKey NVARCHAR(40) COLLATE Chinese_Taiwan_Stroke_CI_AS NOT NULL PRIMARY KEY
    );

    CREATE TABLE #TlfsFallback
    (
          tlfs06 NVARCHAR(40) COLLATE Chinese_Taiwan_Stroke_CI_AS NOT NULL
        , tlfs10 NVARCHAR(40) COLLATE Chinese_Taiwan_Stroke_CI_AS NULL
        , tlfs11 DECIMAL(18,0) NULL
        , tlfs12 DATETIME2(0) NULL
    );

    WHILE EXISTS
    (
        SELECT 1
        FROM #FallbackSearchKey AS k
        WHERE NOT EXISTS
        (
            SELECT 1
            FROM #FallbackLoaded AS d
            WHERE d.SearchKey=k.SearchKey
        )
    )
    BEGIN
        TRUNCATE TABLE #FallbackBatch;

        ;WITH P AS
        (
            SELECT k.SearchKey,
                   LEN(N'''' + REPLACE(k.SearchKey,N'''',N'''''') + N''',') AS KeyChars
            FROM #FallbackSearchKey AS k
            WHERE NOT EXISTS
            (
                SELECT 1
                FROM #FallbackLoaded AS d
                WHERE d.SearchKey=k.SearchKey
            )
        ), R AS
        (
            SELECT SearchKey,
                   SUM(KeyChars) OVER
                   (ORDER BY SearchKey ROWS UNBOUNDED PRECEDING) AS RunningChars
            FROM P
        )
        INSERT INTO #FallbackBatch(SearchKey)
        SELECT SearchKey
        FROM R
        WHERE RunningChars <= 5000;

        IF NOT EXISTS (SELECT 1 FROM #FallbackBatch)
        BEGIN
            INSERT INTO #FallbackBatch(SearchKey)
            SELECT TOP (1) k.SearchKey
            FROM #FallbackSearchKey AS k
            WHERE NOT EXISTS
            (
                SELECT 1
                FROM #FallbackLoaded AS d
                WHERE d.SearchKey=k.SearchKey
            )
            ORDER BY k.SearchKey;
        END;

        SELECT @OracleList=STRING_AGG
        (
            CONVERT(NVARCHAR(MAX),N'''' + REPLACE(SearchKey,N'''',N'''''') + N''''),
            N','
        )
        FROM #FallbackBatch;

        SET @OracleQuery=
              N'SELECT RTRIM(tlfs06) tlfs06,RTRIM(tlfs10) tlfs10,tlfs11,'
            + N'TO_CHAR(MAX(tlfs111),''YYYY-MM-DD HH24:MI:SS'') tlfs12 '
            + N'FROM gfn_202210.tlfs_file '
            + N'WHERE tlfs06 IN (' + @OracleList + N') '
            + N'AND tlfs10 IS NOT NULL '
            + N'GROUP BY tlfs06,tlfs10,tlfs11';

        SET @EscapedOracle=REPLACE(@OracleQuery,NCHAR(39),NCHAR(39)+NCHAR(39));
        IF LEN(@EscapedOracle)>7400
            THROW 50313, N'Fallback TLFS Oracle 查詢超過 OPENQUERY 安全長度。', 1;

        SET @ExecSql=
              N'INSERT INTO #TlfsFallback(tlfs06,tlfs10,tlfs11,tlfs12) '
            + N'SELECT CONVERT(NVARCHAR(40),q.tlfs06),CONVERT(NVARCHAR(40),q.tlfs10),'
            + N'TRY_CONVERT(DECIMAL(18,0),q.tlfs11),TRY_CONVERT(DATETIME2(0),q.tlfs12) '
            + N'FROM OPENQUERY([ORACLE_LINKED_SERVER],'''
            + @EscapedOracle + N''') AS q;';

        SET @CallStart = SYSDATETIME();
        EXEC sys.sp_executesql @ExecSql;
        SET @FallbackOracleMs += DATEDIFF_BIG(MILLISECOND,@CallStart,SYSDATETIME());
        SET @FallbackOracleCalls += 1;

        INSERT INTO #FallbackLoaded(SearchKey)
        SELECT SearchKey
        FROM #FallbackBatch;
    END;

    CREATE INDEX IX_TlfsFallback
        ON #TlfsFallback(tlfs06,tlfs10,tlfs11)
        INCLUDE(tlfs12);

    CREATE TABLE #FallbackCandidate
    (
          SearchKey NVARCHAR(40) COLLATE Chinese_Taiwan_Stroke_CI_AS NOT NULL
        , SourcePriority TINYINT NOT NULL
        , PersonId NVARCHAR(40) NULL
        , PersonName NVARCHAR(100) NULL
        , TlfsDate DATETIME2(0) NULL
    );

    /* 來源單號 fallback：4GL 為 SFV -> RVU -> RVU -> INA；重複 RVU 不另算 */
    INSERT INTO #FallbackCandidate(SearchKey,SourcePriority,PersonId,PersonName,TlfsDate)
    SELECT
          t.tlfs06,1
        , NULLIF(LTRIM(RTRIM(CONVERT(NVARCHAR(40),sfb.sfb44))),N'')
        , NULLIF(LTRIM(RTRIM(CONVERT(NVARCHAR(100),gen.gen02))),N'')
        , t.tlfs12
    FROM #TlfsFallback AS t
    INNER JOIN ERP_Staging.dbo.sfv_file AS sfv
        ON sfv.sfv01=t.tlfs10 AND sfv.sfv03=t.tlfs11
    INNER JOIN ERP_Staging.dbo.sfb_file AS sfb
        ON sfb.sfb01=sfv.sfv11
    LEFT JOIN ERP_Staging.dbo.gen_file AS gen
        ON gen.gen01=sfb.sfb44
    WHERE NULLIF(LTRIM(RTRIM(CONVERT(NVARCHAR(40),sfb.sfb44))),N'') IS NOT NULL;

    INSERT INTO #FallbackCandidate(SearchKey,SourcePriority,PersonId,PersonName,TlfsDate)
    SELECT
          t.tlfs06,2
        , NULLIF(LTRIM(RTRIM(CONVERT(NVARCHAR(40),rvu.rvu07))),N'')
        , NULLIF(LTRIM(RTRIM(CONVERT(NVARCHAR(100),gen.gen02))),N'')
        , t.tlfs12
    FROM #TlfsFallback AS t
    INNER JOIN ERP_Staging.dbo.rvv_file AS rvv
        ON rvv.rvv01=t.tlfs10 AND rvv.rvv02=t.tlfs11
    INNER JOIN ERP_Staging.dbo.rvu_file AS rvu
        ON rvu.rvu01=rvv.rvv01
       AND rvu.rvu00=N'1'
       AND rvu.rvuconf=N'Y'
    LEFT JOIN ERP_Staging.dbo.gen_file AS gen
        ON gen.gen01=rvu.rvu07
    WHERE NULLIF(LTRIM(RTRIM(CONVERT(NVARCHAR(40),rvu.rvu07))),N'') IS NOT NULL;

    INSERT INTO #FallbackCandidate(SearchKey,SourcePriority,PersonId,PersonName,TlfsDate)
    SELECT
          t.tlfs06,4
        , NULLIF(LTRIM(RTRIM(CONVERT(NVARCHAR(40),ina.ina11))),N'')
        , NULLIF(LTRIM(RTRIM(CONVERT(NVARCHAR(100),gen.gen02))),N'')
        , t.tlfs12
    FROM #TlfsFallback AS t
    INNER JOIN ERP_Staging.dbo.ina_file AS ina
        ON ina.ina01=t.tlfs10
       AND ina.inaconf=N'Y'
       AND ina.inapost=N'Y'
       AND ina.ina00 IN (N'2',N'4')
    LEFT JOIN ERP_Staging.dbo.gen_file AS gen
        ON gen.gen01=ina.ina11
    WHERE NULLIF(LTRIM(RTRIM(CONVERT(NVARCHAR(40),ina.ina11))),N'') IS NOT NULL;

    CREATE TABLE #FallbackBest
    (
          SearchKey NVARCHAR(40) COLLATE Chinese_Taiwan_Stroke_CI_AS NOT NULL PRIMARY KEY
        , PersonId NVARCHAR(40) NULL
        , PersonName NVARCHAR(100) NULL
        , SourcePriority TINYINT NOT NULL
    );

    ;WITH R AS
    (
        SELECT SearchKey,PersonId,PersonName,SourcePriority,TlfsDate,
               ROW_NUMBER() OVER
               (
                   PARTITION BY SearchKey
                   ORDER BY SourcePriority,TlfsDate DESC
               ) AS rn
        FROM #FallbackCandidate
        WHERE PersonId IS NOT NULL
    )
    INSERT INTO #FallbackBest(SearchKey,PersonId,PersonName,SourcePriority)
    SELECT SearchKey,PersonId,PersonName,SourcePriority
    FROM R
    WHERE rn=1;

    INSERT INTO @Perf(SortNo,StageName,ElapsedMs,OracleCalls)
    VALUES
          (60,N'06A Fallback TLFS Oracle',@FallbackOracleMs,@FallbackOracleCalls)
        , (61,N'06B Fallback 本機人員判斷',
              DATEDIFF_BIG(MILLISECOND,@FallbackStageStart,SYSDATETIME())-@FallbackOracleMs,NULL)
        , (62,N'06C Fallback 總計',
              DATEDIFF_BIG(MILLISECOND,@FallbackStageStart,SYSDATETIME()),NULL);

    /* 5. 回寫；代碼與姓名永遠取同一來源 */
    DECLARE @UpdatedRows INT;
    SET @StageStart = SYSDATETIME();

    UPDATE s
       SET s.sfu16 = CASE
                         WHEN p.PersonId IS NOT NULL THEN p.PersonId
                         WHEN f.PersonId IS NOT NULL THEN f.PersonId
                         ELSE NULL
                     END,
           s.sfu16_desc = CASE
                              WHEN p.PersonId IS NOT NULL THEN p.PersonName
                              WHEN f.PersonId IS NOT NULL THEN f.PersonName
                              ELSE NULL
                          END
    FROM dbo.InventoryInquirySnapshot AS s
    INNER JOIN #Resolved AS r ON r.InventoryKey=s.InventoryKey
    LEFT JOIN #PrimaryBest AS p ON p.SearchKey=r.ResolvedKey
    LEFT JOIN #FallbackBest AS f ON f.SearchKey=r.SourceOrder
    WHERE s.OperatingCenter = N'GFUN'
      AND
      (
           @OnlyMissing=0
        OR NULLIF(LTRIM(RTRIM(CONVERT(NVARCHAR(100),s.sfu16))),N'') IS NULL
        OR NULLIF(LTRIM(RTRIM(CONVERT(NVARCHAR(500),s.sfu16_desc))),N'') IS NULL
      );

    SET @UpdatedRows=@@ROWCOUNT;

    INSERT INTO @Perf(SortNo,StageName,ElapsedMs,OracleCalls)
    VALUES(70,N'07 UPDATE Snapshot',DATEDIFF_BIG(MILLISECOND,@StageStart,SYSDATETIME()),NULL);

    SELECT
          @AsOfDate AS [計算截止日]
        , (SELECT COUNT(*) FROM #Work) AS [本次處理筆數]
        , @UpdatedRows AS [更新筆數]
        , SUM(CASE WHEN p.PersonId IS NULL AND f.PersonId IS NULL THEN 1 ELSE 0 END) AS [仍無人員筆數]
    FROM #Resolved AS r
    LEFT JOIN #PrimaryBest AS p ON p.SearchKey=r.ResolvedKey
    LEFT JOIN #FallbackBest AS f ON f.SearchKey=r.SourceOrder;

    SELECT
          CASE COALESCE(p.SourcePriority,f.SourcePriority)
              WHEN 1 THEN CASE WHEN p.PersonId IS NOT NULL THEN N'SFV/SFB' ELSE N'SFV/SFB-來源單號' END
              WHEN 2 THEN CASE WHEN p.PersonId IS NOT NULL THEN N'RVU' ELSE N'RVU-來源單號' END
              WHEN 3 THEN N'RVA'
              WHEN 4 THEN CASE WHEN p.PersonId IS NOT NULL THEN N'INA' ELSE N'INA-來源單號' END
          END AS [人員來源]
        , COUNT(*) AS [筆數]
    FROM #Resolved AS r
    LEFT JOIN #PrimaryBest AS p ON p.SearchKey=r.ResolvedKey
    LEFT JOIN #FallbackBest AS f ON f.SearchKey=r.SourceOrder
    WHERE p.PersonId IS NOT NULL OR f.PersonId IS NOT NULL
    GROUP BY
          CASE COALESCE(p.SourcePriority,f.SourcePriority)
              WHEN 1 THEN CASE WHEN p.PersonId IS NOT NULL THEN N'SFV/SFB' ELSE N'SFV/SFB-來源單號' END
              WHEN 2 THEN CASE WHEN p.PersonId IS NOT NULL THEN N'RVU' ELSE N'RVU-來源單號' END
              WHEN 3 THEN N'RVA'
              WHEN 4 THEN CASE WHEN p.PersonId IS NOT NULL THEN N'INA' ELSE N'INA-來源單號' END
          END
    ORDER BY [人員來源];

    INSERT INTO @Perf(SortNo,StageName,ElapsedMs,OracleCalls)
    VALUES(99,N'99 SP 總耗時',DATEDIFF_BIG(MILLISECOND,@PerfStart,SYSDATETIME()),NULL);

    /* 第三個結果集：請看這張即可定位真正瓶頸 */
    SELECT
          StageName AS [階段]
        , ElapsedMs AS [毫秒]
        , CONVERT(DECIMAL(12,3),ElapsedMs/1000.0) AS [秒]
        , OracleCalls AS [Oracle呼叫次數]
    FROM @Perf
    ORDER BY SortNo;
END;


GO
