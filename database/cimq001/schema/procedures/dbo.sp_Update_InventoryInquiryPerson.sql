USE [SAL_MRT];
GO


CREATE   PROCEDURE dbo.sp_Update_InventoryInquiryPerson
(
      @AsOfDate    DATE = NULL
    , @OnlyMissing BIT  = 1
    , @MaxRows     INT  = NULL
)
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    IF @MaxRows IS NOT NULL AND @MaxRows <= 0
        THROW 50301, N'@MaxRows 必須為 NULL 或大於 0。', 1;

    IF @AsOfDate IS NULL
    BEGIN
        SELECT @AsOfDate = MAX(ActivityDate)
        FROM dbo.InventoryInquiryActivity
        WHERE ActivityType = 'TLFS'
          AND OperatingCenter = N'SNX';
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

    /* 1. 興采資料；以 OperatingCenter='SNX' 隔離 */
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
    WHERE s.OperatingCenter = N'SNX'
      AND ISNULL(UPPER(LTRIM(RTRIM(CONVERT(NVARCHAR(100), s.ta_ima01)))), N'') NOT IN (N'D', N'E')
      AND
      (
            @OnlyMissing = 0
         OR NULLIF(LTRIM(RTRIM(CONVERT(NVARCHAR(100), s.sfu16))), N'') IS NULL
         OR NULLIF(LTRIM(RTRIM(CONVERT(NVARCHAR(500), s.sfu16_desc))), N'') IS NULL
      )
    ORDER BY s.InventoryKey;

    CREATE UNIQUE CLUSTERED INDEX IX_Work ON #Work(InventoryKey);

    IF NOT EXISTS (SELECT 1 FROM #Work)
    BEGIN
        SELECT @AsOfDate AS [計算截止日], 0 AS [本次處理筆數], 0 AS [更新筆數], 0 AS [仍無人員筆數];
        RETURN;
    END;

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
              FROM ERP_Staging.dbo.snx_agd_file AS a
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

    /* 2. 一般製造批號：q001_get_tc_imgb07，最多 30 次 */
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
            FROM ERP_Staging.dbo.snx_tc_imga_file AS a
            INNER JOIN ERP_Staging.dbo.snx_tc_img_file AS h
                ON h.tc_img01 = a.tc_imga01
               AND h.tc_imgconf = N'Y'
            INNER JOIN ERP_Staging.dbo.snx_tc_imgb_file AS b
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

    /* 3. 顏色回溯：Oracle 只讀 TLFS_FILE，且 Cursor 內不連 Oracle */
    CREATE TABLE #TlfsKey
    (
          SearchKey NVARCHAR(40) COLLATE Chinese_Taiwan_Stroke_CI_AS NOT NULL PRIMARY KEY
        , Loaded BIT NOT NULL DEFAULT(0)
    );

    CREATE TABLE #TlfsBatch
    (
        SearchKey NVARCHAR(40) COLLATE Chinese_Taiwan_Stroke_CI_AS NOT NULL PRIMARY KEY
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
        , tlfs111 NVARCHAR(40)  COLLATE Chinese_Taiwan_Stroke_CI_AS NULL
    );

    CREATE INDEX IX_TlfsCache
        ON #TlfsCache(tlfs06,tlfs01,tlfs02,tlfs03,tlfs04,tlfs05,tlfs12)
        INCLUDE(tlfs08,tlfs10,tlfs11,tlfs111);

    INSERT INTO #TlfsKey(SearchKey)
    SELECT DISTINCT NULLIF(LTRIM(RTRIM(ResolvedKey)), N'')
    FROM #Resolved
    WHERE IsColor = 1
      AND NULLIF(LTRIM(RTRIM(ResolvedKey)), N'') IS NOT NULL;

    DECLARE
          @OracleList    NVARCHAR(MAX)
        , @OracleQuery   NVARCHAR(MAX)
        , @ExecSql       NVARCHAR(MAX)
        , @EscapedOracle NVARCHAR(MAX)
        , @OracleCutoff  CHAR(10) = CONVERT(CHAR(10), DATEADD(DAY,1,@AsOfDate),120)
        , @ColorRound    INT = 0;

    WHILE EXISTS (SELECT 1 FROM #Resolved WHERE IsColor=1 AND TraceDone=0)
      AND @ColorRound < 20
    BEGIN
        SET @ColorRound += 1;

        WHILE EXISTS (SELECT 1 FROM #TlfsKey WHERE Loaded=0)
        BEGIN
            TRUNCATE TABLE #TlfsBatch;

            ;WITH P AS
            (
                SELECT SearchKey,
                       LEN(N'''' + REPLACE(SearchKey,N'''',N'''''') + N''',') AS KeyChars
                FROM #TlfsKey
                WHERE Loaded=0
            ), R AS
            (
                SELECT SearchKey,
                       SUM(KeyChars) OVER (ORDER BY SearchKey ROWS UNBOUNDED PRECEDING) AS RunningChars
                FROM P
            )
            INSERT INTO #TlfsBatch(SearchKey)
            SELECT SearchKey
            FROM R
            WHERE RunningChars <= 2800;

            IF NOT EXISTS (SELECT 1 FROM #TlfsBatch)
            BEGIN
                INSERT INTO #TlfsBatch(SearchKey)
                SELECT TOP (1) SearchKey FROM #TlfsKey WHERE Loaded=0 ORDER BY SearchKey;
            END;

            SELECT @OracleList = STRING_AGG
            (
                CONVERT(NVARCHAR(MAX),N'''' + REPLACE(SearchKey,N'''',N'''''') + N''''),
                N','
            )
            FROM #TlfsBatch;

            SET @OracleQuery =
                  N'SELECT RTRIM(tlfs01) tlfs01,RTRIM(tlfs02) tlfs02,RTRIM(tlfs03) tlfs03,'
                + N'RTRIM(tlfs04) tlfs04,RTRIM(tlfs05) tlfs05,RTRIM(tlfs06) tlfs06,'
                + N'RTRIM(tlfs08) tlfs08,RTRIM(tlfs10) tlfs10,tlfs11,'
                + N'TO_CHAR(tlfs12,''YYYY-MM-DD HH24:MI:SS'') tlfs12,RTRIM(tlfs111) tlfs111 '
                + N'FROM snx_202012.tlfs_file '
                + N'WHERE tlfs09=1 '
                + N'AND tlfs12 < TO_DATE(''' + @OracleCutoff + N''',''YYYY-MM-DD'') '
                + N'AND tlfs06 IN (' + @OracleList + N')';

            SET @EscapedOracle = REPLACE(@OracleQuery, NCHAR(39), NCHAR(39)+NCHAR(39));
            IF LEN(@EscapedOracle) > 7000
                THROW 50310, N'顏色 TLFS Oracle 查詢超過 OPENQUERY 安全長度。', 1;

            SET @ExecSql =
                  N'INSERT INTO #TlfsCache(tlfs01,tlfs02,tlfs03,tlfs04,tlfs05,tlfs06,tlfs08,tlfs10,tlfs11,tlfs12,tlfs111) '
                + N'SELECT CONVERT(NVARCHAR(40),q.tlfs01),CONVERT(NVARCHAR(40),q.tlfs02),'
                + N'CONVERT(NVARCHAR(40),q.tlfs03),CONVERT(NVARCHAR(40),q.tlfs04),'
                + N'CONVERT(NVARCHAR(40),q.tlfs05),CONVERT(NVARCHAR(40),q.tlfs06),'
                + N'CONVERT(NVARCHAR(100),q.tlfs08),CONVERT(NVARCHAR(40),q.tlfs10),'
                + N'TRY_CONVERT(DECIMAL(18,0),q.tlfs11),TRY_CONVERT(DATETIME2(0),q.tlfs12),'
                + N'CONVERT(NVARCHAR(40),q.tlfs111) '
                + N'FROM OPENQUERY([ORACLE_LINKED_SERVER],'''
                + @EscapedOracle + N''') AS q;';

            EXEC sys.sp_executesql @ExecSql;

            UPDATE k SET Loaded=1
            FROM #TlfsKey AS k
            INNER JOIN #TlfsBatch AS b ON b.SearchKey=k.SearchKey;
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
            , @Tlfs111 NVARCHAR(40)
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
                    SELECT 1 FROM ERP_Staging.dbo.snx_agd_file WHERE agd02=@ResolvedKey
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
                        FROM ERP_Staging.dbo.snx_tc_imga_file AS a
                        INNER JOIN ERP_Staging.dbo.snx_tc_img_file AS h
                            ON h.tc_img01=a.tc_imga01 AND h.tc_imgconf=N'Y'
                        INNER JOIN ERP_Staging.dbo.snx_tc_imgb_file AS b
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

                IF NOT EXISTS (SELECT 1 FROM #TlfsKey WHERE SearchKey=@ResolvedKey AND Loaded=1)
                BEGIN
                    IF NOT EXISTS (SELECT 1 FROM #TlfsKey WHERE SearchKey=@ResolvedKey)
                        INSERT INTO #TlfsKey(SearchKey,Loaded) VALUES(@ResolvedKey,0);
                    ELSE
                        UPDATE #TlfsKey SET Loaded=0 WHERE SearchKey=@ResolvedKey;
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
                      AND f.tlfs12<=@TlfsCutoff
                    ORDER BY f.tlfs12 DESC;

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
                        FROM ERP_Staging.dbo.snx_tlf_file
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
                        SET @TlfsCutoff=@Tlfs12;
                        CONTINUE;
                    END;

                    BREAK;
                END;

                IF @Found=0
                BEGIN
                    SET @RowDone=1;
                    BREAK;
                END;

                IF LEFT(ISNULL(@Tlfs08,N''),6) IN (N'asft62',N'csft62')
                   AND EXISTS
                   (
                       SELECT 1
                       FROM ERP_Staging.dbo.snx_tc_img_file
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
                        FROM ERP_Staging.dbo.snx_tc_imga_file AS a
                        INNER JOIN ERP_Staging.dbo.snx_tc_img_file AS h
                            ON h.tc_img01=a.tc_imga01 AND h.tc_imgconf=N'Y'
                        INNER JOIN ERP_Staging.dbo.snx_tc_imgb_file AS b
                            ON b.tc_imgb01=h.tc_img01 AND b.tc_imgb31=a.tc_imga31
                        WHERE a.tc_imga19=@ResolvedKey
                          AND h.tc_img03=@ItemNo
                          AND a.tc_imga03=@CurrentWarehouse
                          AND ISNULL(a.tc_imga04,N'')=ISNULL(@CurrentLocation,N'')
                          AND ISNULL(a.tc_imga05,N'')=ISNULL(@CurrentLotOrder,N'')
                          AND EXISTS
                          (
                              SELECT 1
                              FROM ERP_Staging.dbo.snx_sfu_file AS u
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
    END;

    IF EXISTS (SELECT 1 FROM #Resolved WHERE IsColor=1 AND TraceDone=0)
        THROW 50311, N'顏色製造批號回溯超過 20 輪，已中止避免無限迴圈。', 1;

    /* 4. 人員查找：Oracle 仍只讀 TLFS_FILE；其他表維持 ERP_Staging */
    SELECT DISTINCT SearchKey
    INTO #SearchKey
    FROM
    (
        SELECT NULLIF(LTRIM(RTRIM(ResolvedKey)),N'') AS SearchKey FROM #Resolved
        UNION
        SELECT NULLIF(LTRIM(RTRIM(SourceOrder)),N'') FROM #Resolved
    ) AS k
    WHERE SearchKey IS NOT NULL;

    CREATE UNIQUE CLUSTERED INDEX IX_SearchKey ON #SearchKey(SearchKey);

    CREATE TABLE #PersonBatch
    (
        SearchKey NVARCHAR(40) COLLATE Chinese_Taiwan_Stroke_CI_AS NOT NULL PRIMARY KEY
    );

    CREATE TABLE #PersonLoaded
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
        FROM #SearchKey AS k
        WHERE NOT EXISTS (SELECT 1 FROM #PersonLoaded AS d WHERE d.SearchKey=k.SearchKey)
    )
    BEGIN
        TRUNCATE TABLE #PersonBatch;

        ;WITH P AS
        (
            SELECT k.SearchKey,
                   LEN(N'''' + REPLACE(k.SearchKey,N'''',N'''''') + N''',') AS KeyChars
            FROM #SearchKey AS k
            WHERE NOT EXISTS (SELECT 1 FROM #PersonLoaded AS d WHERE d.SearchKey=k.SearchKey)
        ), R AS
        (
            SELECT SearchKey,
                   SUM(KeyChars) OVER (ORDER BY SearchKey ROWS UNBOUNDED PRECEDING) AS RunningChars
            FROM P
        )
        INSERT INTO #PersonBatch(SearchKey)
        SELECT SearchKey
        FROM R
        WHERE RunningChars<=3500;

        IF NOT EXISTS (SELECT 1 FROM #PersonBatch)
        BEGIN
            INSERT INTO #PersonBatch(SearchKey)
            SELECT TOP (1) k.SearchKey
            FROM #SearchKey AS k
            WHERE NOT EXISTS (SELECT 1 FROM #PersonLoaded AS d WHERE d.SearchKey=k.SearchKey)
            ORDER BY k.SearchKey;
        END;

        SELECT @OracleList=STRING_AGG
        (
            CONVERT(NVARCHAR(MAX),N'''' + REPLACE(SearchKey,N'''',N'''''') + N''''),
            N','
        )
        FROM #PersonBatch;

        /* 同一 tlfs06/tlfs10/tlfs11 只回傳最新一筆，降低 Oracle -> SQL Server 傳輸量 */
        SET @OracleQuery=
              N'SELECT RTRIM(tlfs06) tlfs06,RTRIM(tlfs10) tlfs10,tlfs11,'
            + N'TO_CHAR(MAX(tlfs12),''YYYY-MM-DD HH24:MI:SS'') tlfs12 '
            + N'FROM snx_202012.tlfs_file '
            + N'WHERE tlfs06 IN (' + @OracleList + N') '
            + N'AND tlfs10 IS NOT NULL '
            + N'GROUP BY tlfs06,tlfs10,tlfs11';

        SET @EscapedOracle = REPLACE(@OracleQuery, NCHAR(39), NCHAR(39)+NCHAR(39));
        IF LEN(@EscapedOracle)>7000
            THROW 50312, N'人員 TLFS Oracle 查詢超過 OPENQUERY 安全長度。', 1;

        SET @ExecSql=
              N'INSERT INTO #TlfsPerson(tlfs06,tlfs10,tlfs11,tlfs12) '
            + N'SELECT CONVERT(NVARCHAR(40),q.tlfs06),CONVERT(NVARCHAR(40),q.tlfs10),'
            + N'TRY_CONVERT(DECIMAL(18,0),q.tlfs11),TRY_CONVERT(DATETIME2(0),q.tlfs12) '
            + N'FROM OPENQUERY([ORACLE_LINKED_SERVER],'''
            + @EscapedOracle + N''') AS q;';

        EXEC sys.sp_executesql @ExecSql;

        INSERT INTO #PersonLoaded(SearchKey)
        SELECT SearchKey FROM #PersonBatch;
    END;

    CREATE INDEX IX_TlfsPerson ON #TlfsPerson(tlfs06,tlfs10,tlfs11) INCLUDE(tlfs12);

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
    INNER JOIN ERP_Staging.dbo.snx_sfv_file AS sfv
        ON sfv.sfv01=t.tlfs10 AND sfv.sfv03=t.tlfs11
    INNER JOIN ERP_Staging.dbo.snx_sfb_file AS sfb
        ON sfb.sfb01=sfv.sfv11
    LEFT JOIN ERP_Staging.dbo.snx_gen_file AS gen
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
    INNER JOIN ERP_Staging.dbo.snx_rvv_file AS rvv
        ON rvv.rvv01=t.tlfs10 AND rvv.rvv02=t.tlfs11
    INNER JOIN ERP_Staging.dbo.snx_rvu_file AS rvu
        ON rvu.rvu01=rvv.rvv01
       AND rvu.rvu00=N'1'
       AND rvu.rvuconf=N'Y'
    LEFT JOIN ERP_Staging.dbo.snx_gen_file AS gen
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
    INNER JOIN ERP_Staging.dbo.snx_rva_file AS rva
        ON rva.rva01=t.tlfs10
       AND rva.rvaconf=N'Y'
    LEFT JOIN ERP_Staging.dbo.snx_gen_file AS gen
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
    INNER JOIN ERP_Staging.dbo.snx_ina_file AS ina
        ON ina.ina01=t.tlfs10
       AND ina.inaconf=N'Y'
       AND ina.inapost=N'Y'
       AND ina.ina00 IN (N'2',N'4')
    LEFT JOIN ERP_Staging.dbo.snx_gen_file AS gen
        ON gen.gen01=ina.ina11
    WHERE NULLIF(LTRIM(RTRIM(CONVERT(NVARCHAR(40),ina.ina11))),N'') IS NOT NULL;

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
    SELECT SearchKey,PersonId,PersonName,SourcePriority
    INTO #PrimaryBest
    FROM R
    WHERE rn=1;

    CREATE UNIQUE CLUSTERED INDEX IX_PrimaryBest ON #PrimaryBest(SearchKey);

    /* 來源單號 fallback：4GL 為 SFV -> RVU -> RVU -> INA，重複 RVU 不另算 */
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
          AND SourcePriority IN (1,2,4)
    )
    SELECT SearchKey,PersonId,PersonName,SourcePriority
    INTO #FallbackBest
    FROM R
    WHERE rn=1;

    CREATE UNIQUE CLUSTERED INDEX IX_FallbackBest ON #FallbackBest(SearchKey);

    /* 5. 回寫；代碼與姓名永遠取同一來源 */
    DECLARE @UpdatedRows INT;

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
    WHERE s.OperatingCenter = N'SNX'
      AND
      (
           @OnlyMissing=0
        OR NULLIF(LTRIM(RTRIM(CONVERT(NVARCHAR(100),s.sfu16))),N'') IS NULL
        OR NULLIF(LTRIM(RTRIM(CONVERT(NVARCHAR(500),s.sfu16_desc))),N'') IS NULL
      );

    SET @UpdatedRows=@@ROWCOUNT;

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
END;

GO
