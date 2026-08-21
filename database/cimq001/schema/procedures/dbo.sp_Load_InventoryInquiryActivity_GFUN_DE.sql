USE [SAL_MRT];
GO



CREATE   PROCEDURE [dbo].[sp_Load_InventoryInquiryActivity_GFUN_DE]
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE
          @ProcessName          SYSNAME      = N'InventoryInquiryActivity_TLFS111_GFUN_DE'
        , @Today                DATE         = CONVERT(DATE, GETDATE())
        , @RecentFromDate       DATE
        , @RecentToDate         DATE
        , @BackfillFromDate     DATE         = NULL
        , @BackfillToDate       DATE         = NULL
        , @BackfillBeforeDate   DATE
        , @OracleMinDate        DATE
        , @OracleMinMonth       DATE
        , @BackfillComplete     BIT
        , @DoBackfill           BIT          = 0
        , @SourceRows           BIGINT       = 0
        , @InsertedRows         BIGINT       = 0
        , @LoadBatchId          UNIQUEIDENTIFIER = NEWID()
        , @LoadedAt             DATETIME2(0) = SYSDATETIME()
        , @OracleSql            NVARCHAR(MAX)
        , @Command              NVARCHAR(MAX)
        , @RecentFromText       CHAR(10)
        , @RecentToText         CHAR(10)
        , @BackfillFromText     CHAR(10)
        , @BackfillToText       CHAR(10)
        , @Quote                NCHAR(1)      = NCHAR(39)
        , @LockResult           INT;

    /*
      防止排程重複執行。
    */
    EXEC @LockResult = sys.sp_getapplock
          @Resource = N'SAL_MRT.InventoryInquiryActivity.TLFS111.GFUN_DE'
        , @LockMode = N'Exclusive'
        , @LockOwner = N'Session'
        , @LockTimeout = 0;

    IF @LockResult < 0
    BEGIN
        THROW 50001, N'同步程序目前已經在執行中。', 1;
    END;

    BEGIN TRY
        IF COL_LENGTH(N'dbo.InventoryInquiryActivity', N'OperatingCenter') IS NULL
        BEGIN
            THROW 50003, N'InventoryInquiryActivity 缺少 OperatingCenter 欄位。', 1;
        END;

        IF NOT EXISTS
        (
            SELECT 1
            FROM dbo.InventoryInquirySnapshot
            WHERE OperatingCenter = N'GFUN'
              AND ta_ima01 IN (N'D', N'E')
        )
        BEGIN
            THROW 50002,
                  N'InventoryInquirySnapshot 尚無資料，請先執行庫存快照 SP。',
                  1;
        END;

        /*
          最近 7 天每次重新同步。
          @RecentToDate 使用明天，確保包含今天全部時間。
        */
        SET @RecentFromDate = DATEADD(DAY, -7, @Today);
        SET @RecentToDate   = DATEADD(DAY,  1, @Today);

        /*
          第一次執行時，取得 Oracle 最早活動日期。

          這只回傳一筆日期，不會將 600 多萬筆資料傳回 SQL Server。
        */
        IF NOT EXISTS
        (
            SELECT 1
            FROM dbo.InventoryInquiryActivityLoadState
            WHERE ProcessName = @ProcessName
        )
        BEGIN
            SELECT
                @OracleMinDate = TRY_CONVERT(DATE, MIN_TLFS111)
            FROM OPENQUERY
            (
                [ORACLE_LINKED_SERVER],
                '
                    SELECT
                        TRUNC(MIN(tlfs111)) AS MIN_TLFS111
                    FROM gfn_202210.tlfs_file t
                    WHERE t.tlfs111 IS NOT NULL
                      AND EXISTS
                          (
                              SELECT 1
                              FROM gfn_202210.ima_file ima
                              WHERE ima.ima01 = t.tlfs01
                                AND ima.ta_ima01 IN (''D'', ''E'')
                          )
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

                /*
                  第一次補本月：
                  補資料區間為本月 1 日至下月 1 日。
                */
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

        /*
          每次向前補一個完整月份。
        */
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

        /*
          Oracle 查詢：

          第一段：最近 7 天。
          第二段：歷史回補的一個月份。
        */
        SET @OracleSql =
              N'SELECT DISTINCT'
            + N'       tlfs01,'
            + N'       tlfs02,'
            + N'       tlfs03,'
            + N'       tlfs04,'
            + N'       tlfs05,'
            + N'       tlfs06,'
            + N'       TRUNC(tlfs111) AS tlfs111 '
            + N'FROM gfn_202210.tlfs_file t '
            + N'WHERE t.tlfs111 >= TO_DATE('
            + @Quote + @RecentFromText + @Quote
            + N',' + @Quote + N'YYYY-MM-DD' + @Quote + N') '
            + N'  AND t.tlfs111 < TO_DATE('
            + @Quote + @RecentToText + @Quote
            + N',' + @Quote + N'YYYY-MM-DD' + @Quote + N')'
            + N'  AND EXISTS (SELECT 1 FROM gfn_202210.ima_file ima'
            + N'              WHERE ima.ima01 = t.tlfs01'
            + N'                AND ima.ta_ima01 IN (' + @Quote + N'D' + @Quote + N',' + @Quote + N'E' + @Quote + N'))';

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
                + N'       TRUNC(tlfs111) AS tlfs111 '
                + N'FROM gfn_202210.tlfs_file t '
                + N'WHERE t.tlfs111 >= TO_DATE('
                + @Quote + @BackfillFromText + @Quote
                + N',' + @Quote + N'YYYY-MM-DD' + @Quote + N') '
                + N'  AND t.tlfs111 < TO_DATE('
                + @Quote + @BackfillToText + @Quote
                + N',' + @Quote + N'YYYY-MM-DD' + @Quote + N')'
            + N'  AND EXISTS (SELECT 1 FROM gfn_202210.ima_file ima'
            + N'              WHERE ima.ima01 = t.tlfs01'
            + N'                AND ima.ta_ima01 IN (' + @Quote + N'D' + @Quote + N',' + @Quote + N'E' + @Quote + N'))';
        END;

        /*
          將 Oracle 查詢包成 OPENQUERY。

          使用 NCHAR(39) 組引號，避免之前發生的
          「遺漏字元字串後面的引號」錯誤。
        */
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
            + N'    TRY_CONVERT(DATE, TLFS111) '
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

        DROP TABLE IF EXISTS #ActivityLoad;

        /*
          對應目前庫存快照。

          前四個欄位必須相等；
          序號及製造批號將 NULL 與空白視為同一個鍵值。
        */
        SELECT DISTINCT
              s.InventoryKey
            , t.ActivityDate
            , CAST('TLFS' AS VARCHAR(10)) AS ActivityType
            , s.imgs01 AS ItemNo
            , s.imgs02 AS WarehouseNo
            , s.imgs03 AS LocationNo
            , s.imgs04 AS LotNo
            , s.imgs05 AS SerialNo
            , s.imgs06 AS ManufacturingLotNo
            , @LoadBatchId AS LoadBatchId
            , @LoadedAt AS LoadedAt
            , CAST(N'GFUN' AS NVARCHAR(20)) AS OperatingCenter
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
          AND s.OperatingCenter = N'GFUN'
          AND s.ta_ima01 IN (N'D', N'E');

        CREATE UNIQUE CLUSTERED INDEX CIX_ActivityLoad
        ON #ActivityLoad
        (
            InventoryKey,
            ActivityDate,
            ActivityType
        );

        BEGIN TRANSACTION;

        /*
          只刪除本次同步的日期範圍。

          不會清空整張 InventoryInquiryActivity。
        */
        DELETE a
        FROM dbo.InventoryInquiryActivity AS a
        WHERE a.ActivityType = 'TLFS'
          AND a.OperatingCenter = N'GFUN'
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
          )
          AND EXISTS
          (
              SELECT 1
              FROM dbo.InventoryInquirySnapshot AS s
              WHERE s.InventoryKey = a.InventoryKey
                AND s.OperatingCenter = N'GFUN'
                AND s.ta_ima01 IN (N'D', N'E')
          );

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

        /*
          本次月份成功後，回補指標往前移一個月。
        */
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

            , LastSourceRows   = @SourceRows
            , LastInsertedRows = @InsertedRows
            , LastSuccessfulAt = @LoadedAt
        WHERE ProcessName = @ProcessName;

        COMMIT TRANSACTION;

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
            , N'GFUN' AS OperatingCenter
            , N'D,E' AS ItemTypeScope
        FROM dbo.InventoryInquiryActivityLoadState
        WHERE ProcessName = @ProcessName;

        EXEC sys.sp_releaseapplock
              @Resource = N'SAL_MRT.InventoryInquiryActivity.TLFS111.GFUN_DE'
            , @LockOwner = N'Session';
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0
            ROLLBACK TRANSACTION;

        EXEC sys.sp_releaseapplock
              @Resource = N'SAL_MRT.InventoryInquiryActivity.TLFS111.GFUN_DE'
            , @LockOwner = N'Session';

        THROW;
    END CATCH;
END;


GO
