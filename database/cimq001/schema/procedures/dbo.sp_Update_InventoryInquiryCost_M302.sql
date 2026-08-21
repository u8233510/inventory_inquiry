USE [SAL_MRT];
GO




CREATE   PROCEDURE dbo.sp_Update_InventoryInquiryCost_M302
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE
          @StartedAt       DATETIME2(0) = SYSDATETIME()
        , @CompletedAt     DATETIME2(0)
        , @SourceCostKeys  BIGINT = 0
        , @SnapshotRows    BIGINT = 0
        , @UpdatedRows     BIGINT = 0
        , @UnmatchedRows   BIGINT = 0;

    /*========================================================
      1. 基本檢查
    ========================================================*/
    IF OBJECT_ID(N'dbo.InventoryInquirySnapshot', N'U') IS NULL
    BEGIN
        THROW 50001,
              N'dbo.InventoryInquirySnapshot 資料表不存在。',
              1;
    END;

    IF COL_LENGTH
       (
           N'dbo.InventoryInquirySnapshot',
           N'ccc23'
       ) IS NULL
    BEGIN
        THROW 50002,
              N'dbo.InventoryInquirySnapshot 缺少 ccc23 欄位。',
              1;
    END;

    IF COL_LENGTH
       (
           N'dbo.InventoryInquirySnapshot',
           N'OperatingCenter'
       ) IS NULL
    BEGIN
        THROW 50005,
              N'dbo.InventoryInquirySnapshot 缺少 OperatingCenter 欄位。',
              1;
    END;

    IF NOT EXISTS
    (
        SELECT 1
        FROM dbo.InventoryInquirySnapshot
        WHERE OperatingCenter = N'M302'
    )
    BEGIN
        THROW 50003,
              N'InventoryInquirySnapshot 尚無 M302 資料，請先執行 sp_Load_InventoryInquirySnapshot_Core_M302。',
              1;
    END;

    SELECT
        @SnapshotRows = COUNT_BIG(*)
    FROM dbo.InventoryInquirySnapshot
    WHERE OperatingCenter = N'M302';

    /*========================================================
      2. 從 Oracle 取得每組庫存對應的最近成本

      Oracle 端先完成：
      - 只處理 M302 imgs08 > 0 的現有庫存
      - 依料號、批號、庫存年月去 ccc_file 找成本
      - 只回傳最近一筆
    ========================================================*/
    DROP TABLE IF EXISTS #CostSource;

    CREATE TABLE #CostSource
    (
          ItemNo          NVARCHAR(100) NOT NULL
        , LotNo           NVARCHAR(100) NOT NULL
        , InventoryYear   INT           NOT NULL
        , InventoryMonth  INT           NOT NULL
        , ccc23           DECIMAL(28,6) NULL
    );

    INSERT INTO #CostSource
    (
          ItemNo
        , LotNo
        , InventoryYear
        , InventoryMonth
        , ccc23
    )
    SELECT
          CONVERT(NVARCHAR(100), ITEM_NO)
        , CONVERT(NVARCHAR(100), LOT_NO)
        , TRY_CONVERT(INT, INVENTORY_YEAR)
        , TRY_CONVERT(INT, INVENTORY_MONTH)
        , TRY_CONVERT(DECIMAL(28,6), CCC23)
    FROM OPENQUERY
    (
        [ORACLE_LINKED_SERVER],
        '
            SELECT
                  ITEM_NO
                , LOT_NO
                , INVENTORY_YEAR
                , INVENTORY_MONTH
                , CCC23
            FROM
            (
                SELECT
                      inv.ITEM_NO
                    , inv.LOT_NO
                    , inv.INVENTORY_YEAR
                    , inv.INVENTORY_MONTH
                    , c.CCC23

                    , ROW_NUMBER() OVER
                      (
                          PARTITION BY
                                inv.ITEM_NO
                              , inv.LOT_NO
                              , inv.INVENTORY_YEAR
                              , inv.INVENTORY_MONTH

                          ORDER BY
                                c.CCC02 DESC
                              , c.CCC03 DESC
                      ) AS RN

                FROM
                (
                    SELECT DISTINCT
                          i.IMGS01 AS ITEM_NO
                        , NVL(i.IMGS04, CHR(32)) AS LOT_NO

                        , EXTRACT
                          (
                              YEAR FROM i.IMGS09
                          ) AS INVENTORY_YEAR

                        , EXTRACT
                          (
                              MONTH FROM i.IMGS09
                          ) AS INVENTORY_MONTH

                    FROM M302_2023.IMGS_FILE i

                    WHERE i.IMGS08 > 0
                      AND i.IMGS09 IS NOT NULL
                ) inv

                INNER JOIN M302_2023.CCC_FILE c
                    ON c.CCC01 = inv.ITEM_NO
                   AND c.CCC08 = inv.LOT_NO

                   AND
                   (
                       c.CCC02 * 12 + c.CCC03
                   )
                   <=
                   (
                       inv.INVENTORY_YEAR * 12
                       + inv.INVENTORY_MONTH
                   )
            )
            WHERE RN = 1
        '
    );

    DELETE FROM #CostSource
    WHERE ItemNo IS NULL
       OR InventoryYear IS NULL
       OR InventoryMonth IS NULL;

    SELECT
        @SourceCostKeys = COUNT_BIG(*)
    FROM #CostSource;

    IF @SourceCostKeys = 0
    BEGIN
        THROW 50004,
              N'未從 Oracle ccc_file 取得任何成本資料，快照未更新。',
              1;
    END;

    CREATE UNIQUE CLUSTERED INDEX CIX_CostSource
    ON #CostSource
    (
          ItemNo
        , LotNo
        , InventoryYear
        , InventoryMonth
    );

    /*========================================================
      3. 更新正式快照

      查不到成本者維持 0。
      全部動作放在同一個交易內。
    ========================================================*/
    BEGIN TRY
        BEGIN TRANSACTION;

        /*
          避免重新載入後，舊成本殘留。
          不會刪除任何庫存資料，只重設 ccc23。
        */
        UPDATE dbo.InventoryInquirySnapshot
        SET ccc23 = 0
        WHERE OperatingCenter = N'M302';

        /*
          依 4GL 條件更新：
          imgs01 + NVL(imgs04,' ') + YEAR/MONTH(imgs09)
        */
        UPDATE s
        SET
            s.ccc23 = ISNULL(c.ccc23, 0)
        FROM dbo.InventoryInquirySnapshot AS s

        INNER JOIN #CostSource AS c
            ON c.ItemNo
                   COLLATE Latin1_General_100_BIN2
             = s.imgs01
                   COLLATE Latin1_General_100_BIN2

           AND c.LotNo
                   COLLATE Latin1_General_100_BIN2
             = ISNULL(s.imgs04, N' ')
                   COLLATE Latin1_General_100_BIN2

           AND c.InventoryYear =
               DATEPART(YEAR, s.imgs09)

           AND c.InventoryMonth =
               DATEPART(MONTH, s.imgs09)

        WHERE s.OperatingCenter = N'M302';

        SET @UpdatedRows = @@ROWCOUNT;

        COMMIT TRANSACTION;

        SET @CompletedAt = SYSDATETIME();
        SET @UnmatchedRows = @SnapshotRows - @UpdatedRows;

        SELECT
              @SourceCostKeys AS OracleCostKeys
            , @SnapshotRows AS SnapshotRows
            , @UpdatedRows AS UpdatedRows
            , @UnmatchedRows AS UnmatchedRows
            , @StartedAt AS StartedAt
            , @CompletedAt AS CompletedAt
            , DATEDIFF
              (
                  SECOND,
                  @StartedAt,
                  @CompletedAt
              ) AS ElapsedSeconds
            , N'M302' AS OperatingCenter;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0
            ROLLBACK TRANSACTION;

        THROW;
    END CATCH;
END;



GO
