USE [SAL_MRT];
GO



CREATE   PROCEDURE [dbo].[sp_Load_InventoryInquirySnapshot_Core]
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @LoadBatchId UNIQUEIDENTIFIER = NEWID();
    DECLARE @SnapshotTime DATETIME2(0) = SYSDATETIME();
    DECLARE @InsertedRows INT;

    DROP TABLE IF EXISTS #SnapshotLoad;

    /*
    ===========================================================================
    INJ 改由 Oracle Linked Server 即時讀取，不再依賴
    ERP_Staging.dbo.snx_inj_file 的完整同步。

    Oracle 端先以目前仍有庫存的 imgs_file 篩選，避免將整張 inj_file
    拉回 SQL Server。以下假設 Oracle Owner 為 SNX_202012。
    ===========================================================================
    */
    DROP TABLE IF EXISTS #OracleInj;

    CREATE TABLE #OracleInj
    (
          /*
            使用 SAL_MRT 的資料庫預設定序。
            ERP_Staging 的庫存欄位目前是 Chinese_Taiwan_Stroke_CI_AS，
            可避免與先前 Latin1_General_100_BIN2 的直接 JOIN 發生 468 錯誤。
          */
          inj01 NVARCHAR(100)  COLLATE DATABASE_DEFAULT NOT NULL
        , inj02 NVARCHAR(100)  COLLATE DATABASE_DEFAULT NOT NULL
        , inj03 NVARCHAR(50)   COLLATE DATABASE_DEFAULT NULL
        , inj04 NVARCHAR(1000) COLLATE DATABASE_DEFAULT NULL
    );

    INSERT INTO #OracleInj
    (
          inj01
        , inj02
        , inj03
        , inj04
    )
    SELECT
          CONVERT(NVARCHAR(100),  q.inj01)
        , CONVERT(NVARCHAR(100),  q.inj02)
        , CONVERT(NVARCHAR(50),   q.inj03)
        , CONVERT(NVARCHAR(1000), q.inj04)
    FROM OPENQUERY
    (
        [ORACLE_LINKED_SERVER],
        '
            SELECT
                  inj.inj01
                , inj.inj02
                , inj.inj03
                , inj.inj04
            FROM SNX_202012.inj_file inj
            WHERE inj.inj03 IS NOT NULL
              AND EXISTS
                  (
                      SELECT 1
                      FROM SNX_202012.imgs_file i
                      WHERE i.imgs01 = inj.inj01
                        AND i.imgs06 = inj.inj02
                        AND NVL(i.imgs08, 0) > 0
                  )
        '
    ) AS q
    WHERE q.inj01 IS NOT NULL
      AND q.inj02 IS NOT NULL;

    CREATE NONCLUSTERED INDEX IX_OracleInj_Key
        ON #OracleInj
        (
              inj01
            , inj02
            , inj03
        )
        INCLUDE (inj04);


    ;WITH LatestBmz AS
    (
        SELECT
            b.*,
            ROW_NUMBER() OVER
            (
                PARTITION BY
                    b.tc_bmz07,
                    b.tc_bmz09
                ORDER BY
                    ISNULL
                    (
                        TRY_CONVERT(DATETIME2(0), b.tc_bmz12),
                        CONVERT(DATETIME2(0), '2001-01-01')
                    ) DESC,
                    b.tc_bmz01 DESC
            ) AS rn
        FROM ERP_Staging.dbo.snx_tc_bmz_file AS b
    ),
    InjPivot AS
    (
        /*
          4GL 已確認的動態特性代碼：
            S008 = 等級
            S011 = 收布編號
            S012 = 廠商料號
            S025 = 備註
            S026 = 來源項次
            S027 = 來源單號
            S028 = 訂單項次

          依料號 + 製造批號彙總成固定欄位，
          避免直接 JOIN inj_file 造成 Snapshot 重複列。
        */
        SELECT
            inj.inj01,
            inj.inj02,
            MAX(CASE WHEN inj.inj03 = N'S008'
                     THEN NULLIF(RTRIM(CONVERT(NVARCHAR(1000), inj.inj04)), N'') END) AS grade,
            MAX(CASE WHEN inj.inj03 = N'S011'
                     THEN NULLIF(RTRIM(CONVERT(NVARCHAR(1000), inj.inj04)), N'') END) AS receive_cloth_no,
            MAX(CASE WHEN inj.inj03 = N'S012'
                     THEN NULLIF(RTRIM(CONVERT(NVARCHAR(1000), inj.inj04)), N'') END) AS vendor_item_no,
            MAX(CASE WHEN inj.inj03 = N'S025'
                     THEN NULLIF(RTRIM(CONVERT(NVARCHAR(1000), inj.inj04)), N'') END) AS inventory_memo,
            MAX(CASE WHEN inj.inj03 = N'S026'
                     THEN NULLIF(RTRIM(CONVERT(NVARCHAR(1000), inj.inj04)), N'') END) AS source_item,
            MAX(CASE WHEN inj.inj03 = N'S027'
                     THEN NULLIF(RTRIM(CONVERT(NVARCHAR(1000), inj.inj04)), N'') END) AS source_order,
            MAX(CASE WHEN inj.inj03 = N'S028'
                     THEN NULLIF(RTRIM(CONVERT(NVARCHAR(1000), inj.inj04)), N'') END) AS sales_order_item
        FROM #OracleInj AS inj
        WHERE inj.inj03 IN
              (N'S008', N'S011', N'S012', N'S025', N'S026', N'S027', N'S028')
        GROUP BY
            inj.inj01,
            inj.inj02
    ),
    SourcePair AS
    (
        SELECT DISTINCT
            CONVERT(NVARCHAR(100), p.source_order) AS SourceOrder,
            CONVERT(NVARCHAR(100), p.source_item)  AS SourceItem
        FROM InjPivot AS p
        WHERE NULLIF(LTRIM(RTRIM(CONVERT(NVARCHAR(100), p.source_order))), N'') IS NOT NULL
          AND NULLIF(LTRIM(RTRIM(CONVERT(NVARCHAR(100), p.source_item))),  N'') IS NOT NULL
    ),
    PurchaseReceiptCandidate AS
    (
        /* 4GL q001_rvv36_p：rvv36 UNION rvb04 */
        SELECT
            s.SourceOrder,
            s.SourceItem,
            NULLIF(LTRIM(RTRIM(CONVERT(NVARCHAR(100), r.rvv36))), N'') AS PurchaseOrder
        FROM SourcePair AS s
        INNER JOIN ERP_Staging.dbo.snx_rvv_file AS r
            ON CONVERT(NVARCHAR(100), r.rvv01) COLLATE Latin1_General_100_BIN2
               = s.SourceOrder COLLATE Latin1_General_100_BIN2
           AND CONVERT(NVARCHAR(100), r.rvv02) COLLATE Latin1_General_100_BIN2
               = s.SourceItem COLLATE Latin1_General_100_BIN2

        UNION ALL

        SELECT
            s.SourceOrder,
            s.SourceItem,
            NULLIF(LTRIM(RTRIM(CONVERT(NVARCHAR(100), r.rvb04))), N'') AS PurchaseOrder
        FROM SourcePair AS s
        INNER JOIN ERP_Staging.dbo.snx_rvb_file AS r
            ON CONVERT(NVARCHAR(100), r.rvb01) COLLATE Latin1_General_100_BIN2
               = s.SourceOrder COLLATE Latin1_General_100_BIN2
           AND CONVERT(NVARCHAR(100), r.rvb02) COLLATE Latin1_General_100_BIN2
               = s.SourceItem COLLATE Latin1_General_100_BIN2
    ),
    PurchaseReceipt AS
    (
        SELECT
            SourceOrder,
            SourceItem,
            MAX(PurchaseOrder) AS PurchaseOrder
        FROM PurchaseReceiptCandidate
        WHERE PurchaseOrder IS NOT NULL
        GROUP BY
            SourceOrder,
            SourceItem
    ),
    CompletionBase AS
    (
        SELECT DISTINCT
            s.SourceOrder,
            s.SourceItem,
            f.sfv11
        FROM SourcePair AS s
        INNER JOIN ERP_Staging.dbo.snx_sfv_file AS f
            ON CONVERT(NVARCHAR(100), f.sfv01) COLLATE Latin1_General_100_BIN2
               = s.SourceOrder COLLATE Latin1_General_100_BIN2
           AND CONVERT(NVARCHAR(100), f.sfv03) COLLATE Latin1_General_100_BIN2
               = s.SourceItem COLLATE Latin1_General_100_BIN2
    ),
    CompletionLastProcess AS
    (
        SELECT
            c.SourceOrder,
            c.SourceItem,
            c.sfv11,
            MAX(e.ecm03) AS MaxEcm03
        FROM CompletionBase AS c
        INNER JOIN ERP_Staging.dbo.snx_ecm_file AS e
            ON e.ecm01 = c.sfv11
        GROUP BY
            c.SourceOrder,
            c.SourceItem,
            c.sfv11
    ),
    CompletePurchaseOrder AS
    (
        /* 4GL q001_get_complete：sfv11 → MAX(ecm03) → pmn01 */
        SELECT
            p.SourceOrder,
            p.SourceItem,
            MAX
            (
                NULLIF
                (
                    LTRIM(RTRIM(CONVERT(NVARCHAR(100), m.pmn01))),
                    N''
                )
            ) AS PurchaseOrder
        FROM CompletionLastProcess AS p
        INNER JOIN ERP_Staging.dbo.snx_pmn_file AS m
            ON m.pmn41 = p.sfv11
           AND m.pmn46 = p.MaxEcm03
        GROUP BY
            p.SourceOrder,
            p.SourceItem
    ),
    CurrentInventoryKey AS
    (
        SELECT DISTINCT
            i.imgs01,
            i.imgs06
        FROM ERP_Staging.dbo.snx_imgs_file AS i
        WHERE TRY_CONVERT(DECIMAL(28,6), i.imgs08) > 0
    ),
    ImacDistinct AS
    (
        /*
          4GL：
          SELECT DISTINCT imac04
          FROM imac_file
          WHERE imac01 = ?
          ORDER BY imac04
        */
        SELECT DISTINCT
            imac.imac01,
            imac.imac04
        FROM ERP_Staging.dbo.snx_imac_file AS imac
        WHERE NULLIF
              (
                  RTRIM(CONVERT(NVARCHAR(50), imac.imac04)),
                  N''
              ) IS NOT NULL
    ),
    ImacRanked AS
    (
        SELECT
            d.imac01,
            d.imac04,
            ROW_NUMBER() OVER
            (
                PARTITION BY d.imac01
                ORDER BY d.imac04
            ) AS AttributeNo
        FROM ImacDistinct AS d
    ),
    InjValue AS
    (
        /*
          依 4GL 的 inj01 + inj02 + inj03 取得 inj04。
          如同一組鍵有多筆，先以 MAX 取一個確定值，
          最後另提供重複資料診斷。
        */
        SELECT
            inj.inj01,
            inj.inj02,
            inj.inj03,
            MAX
            (
                NULLIF
                (
                    RTRIM(CONVERT(NVARCHAR(1000), inj.inj04)),
                    N''
                )
            ) AS AttributeValue
        FROM #OracleInj AS inj
        WHERE inj.inj03 IS NOT NULL
        GROUP BY
            inj.inj01,
            inj.inj02,
            inj.inj03
    ),
    AttPivot AS
    (
        SELECT
            k.imgs01,
            k.imgs06,
            MAX(CASE WHEN d.AttributeNo = 1
                     THEN CONVERT(NVARCHAR(50), d.imac04) END) AS att01_code,
            MAX(CASE WHEN d.AttributeNo = 1
                     THEN CONVERT(NVARCHAR(500), ini.ini02) END) AS att01_name,
            MAX(CASE WHEN d.AttributeNo = 1
                     THEN v.AttributeValue END) AS att01,
            MAX(CASE WHEN d.AttributeNo = 2
                     THEN CONVERT(NVARCHAR(50), d.imac04) END) AS att02_code,
            MAX(CASE WHEN d.AttributeNo = 2
                     THEN CONVERT(NVARCHAR(500), ini.ini02) END) AS att02_name,
            MAX(CASE WHEN d.AttributeNo = 2
                     THEN v.AttributeValue END) AS att02,
            MAX(CASE WHEN d.AttributeNo = 3
                     THEN CONVERT(NVARCHAR(50), d.imac04) END) AS att03_code,
            MAX(CASE WHEN d.AttributeNo = 3
                     THEN CONVERT(NVARCHAR(500), ini.ini02) END) AS att03_name,
            MAX(CASE WHEN d.AttributeNo = 3
                     THEN v.AttributeValue END) AS att03,
            MAX(CASE WHEN d.AttributeNo = 4
                     THEN CONVERT(NVARCHAR(50), d.imac04) END) AS att04_code,
            MAX(CASE WHEN d.AttributeNo = 4
                     THEN CONVERT(NVARCHAR(500), ini.ini02) END) AS att04_name,
            MAX(CASE WHEN d.AttributeNo = 4
                     THEN v.AttributeValue END) AS att04,
            MAX(CASE WHEN d.AttributeNo = 5
                     THEN CONVERT(NVARCHAR(50), d.imac04) END) AS att05_code,
            MAX(CASE WHEN d.AttributeNo = 5
                     THEN CONVERT(NVARCHAR(500), ini.ini02) END) AS att05_name,
            MAX(CASE WHEN d.AttributeNo = 5
                     THEN v.AttributeValue END) AS att05,
            MAX(CASE WHEN d.AttributeNo = 6
                     THEN CONVERT(NVARCHAR(50), d.imac04) END) AS att06_code,
            MAX(CASE WHEN d.AttributeNo = 6
                     THEN CONVERT(NVARCHAR(500), ini.ini02) END) AS att06_name,
            MAX(CASE WHEN d.AttributeNo = 6
                     THEN v.AttributeValue END) AS att06,
            MAX(CASE WHEN d.AttributeNo = 7
                     THEN CONVERT(NVARCHAR(50), d.imac04) END) AS att07_code,
            MAX(CASE WHEN d.AttributeNo = 7
                     THEN CONVERT(NVARCHAR(500), ini.ini02) END) AS att07_name,
            MAX(CASE WHEN d.AttributeNo = 7
                     THEN v.AttributeValue END) AS att07,
            MAX(CASE WHEN d.AttributeNo = 8
                     THEN CONVERT(NVARCHAR(50), d.imac04) END) AS att08_code,
            MAX(CASE WHEN d.AttributeNo = 8
                     THEN CONVERT(NVARCHAR(500), ini.ini02) END) AS att08_name,
            MAX(CASE WHEN d.AttributeNo = 8
                     THEN v.AttributeValue END) AS att08,
            MAX(CASE WHEN d.AttributeNo = 9
                     THEN CONVERT(NVARCHAR(50), d.imac04) END) AS att09_code,
            MAX(CASE WHEN d.AttributeNo = 9
                     THEN CONVERT(NVARCHAR(500), ini.ini02) END) AS att09_name,
            MAX(CASE WHEN d.AttributeNo = 9
                     THEN v.AttributeValue END) AS att09,
            MAX(CASE WHEN d.AttributeNo = 10
                     THEN CONVERT(NVARCHAR(50), d.imac04) END) AS att10_code,
            MAX(CASE WHEN d.AttributeNo = 10
                     THEN CONVERT(NVARCHAR(500), ini.ini02) END) AS att10_name,
            MAX(CASE WHEN d.AttributeNo = 10
                     THEN v.AttributeValue END) AS att10
        FROM CurrentInventoryKey AS k
        LEFT JOIN ImacRanked AS d
            ON d.imac01 COLLATE Latin1_General_100_BIN2
               = k.imgs01 COLLATE Latin1_General_100_BIN2
           AND d.AttributeNo <= 10
        LEFT JOIN ERP_Staging.dbo.snx_ini_file AS ini
            ON ini.ini01 COLLATE Latin1_General_100_BIN2
               = d.imac04 COLLATE Latin1_General_100_BIN2
        LEFT JOIN InjValue AS v
            ON v.inj01 COLLATE Latin1_General_100_BIN2
               = k.imgs01 COLLATE Latin1_General_100_BIN2
           AND v.inj02 COLLATE Latin1_General_100_BIN2
               = k.imgs06 COLLATE Latin1_General_100_BIN2
           AND v.inj03 COLLATE Latin1_General_100_BIN2
               = d.imac04 COLLATE Latin1_General_100_BIN2
        GROUP BY
            k.imgs01,
            k.imgs06
    )
    SELECT
        /*
          一般庫存 zero = N。

          InventoryKey 是庫存關聯鍵，
          允許多筆資料使用相同 InventoryKey。
        */
        HASHBYTES
        (
            'SHA2_256',
            CONCAT
            (
                N'N|',
                RTRIM(ISNULL(CONVERT(NVARCHAR(100), i.imgs01), N'')), N'|',
                RTRIM(ISNULL(CONVERT(NVARCHAR(50),  i.imgs02), N'')), N'|',
                RTRIM(ISNULL(CONVERT(NVARCHAR(50),  i.imgs03), N'')), N'|',
                RTRIM(ISNULL(CONVERT(NVARCHAR(100), i.imgs04), N'')), N'|',
                RTRIM(ISNULL(CONVERT(NVARCHAR(100), i.imgs05), N'')), N'|',
                RTRIM(ISNULL(CONVERT(NVARCHAR(100), i.imgs06), N''))
            )
        ) AS InventoryKey,

        @LoadBatchId AS LoadBatchId,
        @SnapshotTime AS SnapshotTime,

        CAST(N'N' AS NVARCHAR(1)) AS sel,
        CAST(N'N' AS NVARCHAR(1)) AS [zero],

        imv.tc_imv01,

        i.imgs01,
        ima.ima02,
        ima.ta_ima158,
        ima.ima021,

        i.imgs02,
        imd.imd02,
        i.imgs03,
        ime.ime03,

        i.imgs04,
        i.imgs06,
        color_tqa.tqa02 AS imgs06_desc,
        i.imgs05,
        size_tqa.tqa02 AS imgs05_desc,

        TRY_CONVERT(DATE, i.imgs09) AS imgs09,
        TRY_CONVERT(DECIMAL(28,6), i.imgs08) AS imgs08,
        i.imgs07,

        att.att01,
        att.att02,

        bmz.tc_bmz11,
        rvbs.tc_rvbs22,
        rvbs.tc_rvbs23,
        rvbs.tc_rvbs24,
        imt.tc_imt02 AS tc_rvbs24_desc,
        rvbs.tc_rvbs25,
        imu.tc_imu02 AS tc_rvbs25_desc,

        att.att03,
        att.att04,
        att.att05,
        att.att06,
        att.att07,
        att.att08,
        att.att09,
        att.att10,

        att.att01_code,
        att.att01_name,
        att.att02_code,
        att.att02_name,
        att.att03_code,
        att.att03_name,
        att.att04_code,
        att.att04_name,
        att.att05_code,
        att.att05_name,
        att.att06_code,
        att.att06_name,
        att.att07_code,
        att.att07_name,
        att.att08_code,
        att.att08_name,
        att.att09_code,
        att.att09_name,
        att.att10_code,
        att.att10_name,

        CAST
        (
            CASE
                /* 4GL 類型 2/3/4 直接以採購入庫來源為主 */
                WHEN ima.ta_ima01 IN (N'2', N'3', N'4')
                    THEN COALESCE(pr.PurchaseOrder, cp.PurchaseOrder)

                /* 類型 1/8/9 先判斷完工入庫，再回退採購入庫 */
                ELSE COALESCE(cp.PurchaseOrder, pr.PurchaseOrder)
            END
            AS NVARCHAR(100)
        ) AS pmm01,
        oad.tc_oad03,

        oea_file.ta_oea01 AS ta_oea01_b,
        occ.occ02 AS occ02,

        CASE
            WHEN ima.ta_ima01 = N'3' AND ima.ta_ima91 = N'1' THEN NULL
            ELSE rvbs.tc_rvbs05
        END AS ta_sfb05,
        CASE
            WHEN ima.ta_ima01 = N'3' AND ima.ta_ima91 = N'1' THEN NULL
            ELSE rvbs.tc_rvbs04
        END AS ta_sfb04,
        CASE
            WHEN ima.ta_ima01 = N'3' AND ima.ta_ima91 = N'1' THEN NULL
            ELSE rvbs.tc_rvbs06
        END AS ta_sfb06,
        CASE
            WHEN ima.ta_ima01 = N'3' AND ima.ta_ima91 = N'1' THEN NULL
            ELSE rvbs.tc_rvbs07
        END AS ta_sfb38,

        CAST(N'' AS NVARCHAR(100)) AS pmn06,
        CAST(N'' AS NVARCHAR(100)) AS pmc01,
        CAST(N'' AS NVARCHAR(500)) AS pmc03,
        CAST(N'' AS NVARCHAR(500)) AS ta_ima39,
        CAST(N'' AS NVARCHAR(500)) AS mse02,

        ima.ta_ima91,
        COALESCE(oeb.oeb70, oea_file.ta_oea05) AS ta_oea05_b,

        TRY_CONVERT(DATE, oeb.oeb70d) AS oeb70d,

        oea_file.oea14,
        gen.gen02 AS oea14_desc,
        oea_file.oea15,
        oea_gem.gem02 AS oea15_desc,

        i.ta_imgs01,
        azf.azf03 AS ta_imgs01_d,
        i.ta_imgs02,
        imgs_gem.gem02 AS ta_imgs02_d,

        CAST(N'' AS NVARCHAR(100)) AS sfu16,
        CAST(N'' AS NVARCHAR(500)) AS sfu16_desc,

        oea_file.oeaud04,

        TRY_CONVERT(DATE, oeb.oeb15) AS oeb15,

        CASE
            WHEN i.imgs04 LIKE N'A3101%' THEN N'Y'
            WHEN oea_file.ta_oea11 = N'F105' THEN N'Y'
            ELSE N'N'
        END AS prepare,

        CAST(0 AS DECIMAL(28,6)) AS ccc23,

        attr.source_order,
        attr.source_item,
        attr.sales_order_item,
        attr.grade,
        attr.receive_cloth_no,
        attr.vendor_item_no,
        attr.inventory_memo,

        ima.ta_ima01,
        ima.ta_ima20,
        ima.ta_ima84,  -- 1=彈性，2=非彈性
        oea_file.ta_oea11

    INTO #SnapshotLoad

    FROM ERP_Staging.dbo.snx_imgs_file AS i

    INNER JOIN ERP_Staging.dbo.snx_img_file AS img
    ON img.img01 COLLATE Latin1_General_100_BIN2
       = i.imgs01 COLLATE Latin1_General_100_BIN2

   AND img.img02 COLLATE Latin1_General_100_BIN2
       = i.imgs02 COLLATE Latin1_General_100_BIN2

   AND img.img03 COLLATE Latin1_General_100_BIN2
       = i.imgs03 COLLATE Latin1_General_100_BIN2

   AND img.img04 COLLATE Latin1_General_100_BIN2
       = i.imgs04 COLLATE Latin1_General_100_BIN2

    INNER JOIN ERP_Staging.dbo.snx_ima_file AS ima
        ON ima.ima01 = img.img01

    INNER JOIN ERP_Staging.dbo.snx_imd_file AS imd
        ON imd.imd01 = i.imgs02

    LEFT JOIN ERP_Staging.dbo.snx_tc_imv_file AS imv
        ON  imv.tc_imv02 = i.imgs01
        AND imv.tc_imv03 = i.imgs06
        AND imv.tc_imv04 = i.imgs05

    LEFT JOIN ERP_Staging.dbo.snx_tc_rvbs_file AS rvbs
        ON  rvbs.tc_rvbs01 = i.imgs01
        AND rvbs.tc_rvbs02 = i.imgs04
        AND rvbs.tc_rvbs03 = i.imgs06

    /*
      使用 BIN2 精確比對，避免大小寫或特殊字元
      被 SQL Server 預設 Collation 視為相同。
    */
    LEFT JOIN ERP_Staging.dbo.snx_ime_file AS ime
        ON ime.ime01 COLLATE Latin1_General_100_BIN2
           = i.imgs02 COLLATE Latin1_General_100_BIN2
       AND ime.ime02 COLLATE Latin1_General_100_BIN2
           = i.imgs03 COLLATE Latin1_General_100_BIN2

    LEFT JOIN ERP_Staging.dbo.snx_tqa_file AS color_tqa
        ON color_tqa.tqa01 COLLATE Latin1_General_100_BIN2
           = i.imgs06 COLLATE Latin1_General_100_BIN2
       AND color_tqa.tqa03 COLLATE Latin1_General_100_BIN2
           = N'25' COLLATE Latin1_General_100_BIN2

    LEFT JOIN ERP_Staging.dbo.snx_tqa_file AS size_tqa
        ON size_tqa.tqa01 COLLATE Latin1_General_100_BIN2
           = i.imgs05 COLLATE Latin1_General_100_BIN2
       AND size_tqa.tqa03 COLLATE Latin1_General_100_BIN2
           = N'26' COLLATE Latin1_General_100_BIN2

    LEFT JOIN ERP_Staging.dbo.snx_tc_imt_file AS imt
        ON imt.tc_imt01 = rvbs.tc_rvbs24

    LEFT JOIN ERP_Staging.dbo.snx_tc_imu_file AS imu
        ON imu.tc_imu01 = rvbs.tc_rvbs25

    LEFT JOIN #OracleInj AS inj
        ON  inj.inj01 COLLATE DATABASE_DEFAULT
            = i.imgs01 COLLATE DATABASE_DEFAULT
        AND inj.inj02 COLLATE DATABASE_DEFAULT
            = i.imgs06 COLLATE DATABASE_DEFAULT
        AND inj.inj03 = N'S010'

    LEFT JOIN LatestBmz AS bmz
        ON  bmz.tc_bmz07 = i.imgs01
        AND bmz.tc_bmz09 COLLATE DATABASE_DEFAULT
            = inj.inj04 COLLATE DATABASE_DEFAULT
        AND bmz.rn = 1

    LEFT JOIN InjPivot AS attr
        ON attr.inj01 COLLATE Latin1_General_100_BIN2
           = i.imgs01 COLLATE Latin1_General_100_BIN2
       AND attr.inj02 COLLATE Latin1_General_100_BIN2
           = i.imgs06 COLLATE Latin1_General_100_BIN2

    LEFT JOIN AttPivot AS att
        ON att.imgs01 COLLATE Latin1_General_100_BIN2
           = i.imgs01 COLLATE Latin1_General_100_BIN2
       AND att.imgs06 COLLATE Latin1_General_100_BIN2
           = i.imgs06 COLLATE Latin1_General_100_BIN2

    LEFT JOIN PurchaseReceipt AS pr
        ON pr.SourceOrder COLLATE Latin1_General_100_BIN2
           = CONVERT(NVARCHAR(100), attr.source_order) COLLATE Latin1_General_100_BIN2
       AND pr.SourceItem COLLATE Latin1_General_100_BIN2
           = CONVERT(NVARCHAR(100), attr.source_item) COLLATE Latin1_General_100_BIN2

    LEFT JOIN CompletePurchaseOrder AS cp
        ON cp.SourceOrder COLLATE Latin1_General_100_BIN2
           = CONVERT(NVARCHAR(100), attr.source_order) COLLATE Latin1_General_100_BIN2
       AND cp.SourceItem COLLATE Latin1_General_100_BIN2
           = CONVERT(NVARCHAR(100), attr.source_item) COLLATE Latin1_General_100_BIN2

    LEFT JOIN ERP_Staging.dbo.snx_gem_file AS imgs_gem
        ON imgs_gem.gem01 = i.ta_imgs02

    LEFT JOIN ERP_Staging.dbo.snx_azf_file AS azf
        ON  azf.azf01 = i.ta_imgs01
        AND azf.azf02 = N'2'

    LEFT JOIN ERP_Staging.dbo.snx_oea_file AS oea_file
        ON oea_file.oea01 = img.img04

    LEFT JOIN ERP_Staging.dbo.snx_occ_file AS occ
        ON occ.occ01 COLLATE Latin1_General_100_BIN2
           = oea_file.ta_oea01 COLLATE Latin1_General_100_BIN2

    /*
      4GL q001_oeb70_p：
      oeb01 = imgs04，oeb03 = S028 訂單項次。
    */
    LEFT JOIN ERP_Staging.dbo.snx_oeb_file AS oeb
        ON oeb.oeb01 COLLATE Latin1_General_100_BIN2
           = i.imgs04 COLLATE Latin1_General_100_BIN2
       AND CONVERT(NVARCHAR(100), oeb.oeb03) COLLATE Latin1_General_100_BIN2
           = CONVERT(NVARCHAR(100), attr.sales_order_item) COLLATE Latin1_General_100_BIN2

    LEFT JOIN ERP_Staging.dbo.snx_gen_file AS gen
        ON gen.gen01 = oea_file.oea14

    LEFT JOIN ERP_Staging.dbo.snx_gem_file AS oea_gem
        ON oea_gem.gem01 = oea_file.oea15

    LEFT JOIN ERP_Staging.dbo.snx_tc_oad_file AS oad
        ON  oad.tc_oad01 =
            CASE
                WHEN oea_file.ta_oea01 IS NOT NULL THEN N'1'
                ELSE N'2'
            END
        AND oad.tc_oad02 = oea_file.ta_oea11

    WHERE TRY_CONVERT(DECIMAL(28,6), i.imgs08) > 0
      AND LTRIM(RTRIM(ISNULL(ima.ta_ima01, N'')))
          NOT IN (N'D', N'E');

    /*
    ===========================================================================
    廠商／廠牌補值：在 #SnapshotLoad 完成後，以小型暫存表處理。

    重點：
      1. SourceItem 只轉換一次為 NUMERIC(5,0)。
      2. 不再對 ERP_Staging 的索引欄位做 CONVERT()。
      3. 使用步驟 21 建立的索引。
    ===========================================================================
    */

    CREATE TABLE #SourcePair
    (
          SourceOrder NVARCHAR(40)
              COLLATE Chinese_Taiwan_Stroke_CI_AS NOT NULL
        , SourceItem  NUMERIC(5,0) NOT NULL
        , CONSTRAINT PK_SourcePair
              PRIMARY KEY CLUSTERED (SourceOrder, SourceItem)
    );

    INSERT INTO #SourcePair
    (
        SourceOrder,
        SourceItem
    )
    SELECT
          CONVERT(NVARCHAR(40), s.source_order)
              COLLATE Chinese_Taiwan_Stroke_CI_AS
        , TRY_CONVERT(NUMERIC(5,0), s.source_item)
    FROM #SnapshotLoad AS s
    WHERE NULLIF
          (
              LTRIM(RTRIM(CONVERT(NVARCHAR(40), s.source_order))),
              N''
          ) IS NOT NULL
      AND TRY_CONVERT(NUMERIC(5,0), s.source_item) IS NOT NULL
    GROUP BY
          CONVERT(NVARCHAR(40), s.source_order)
              COLLATE Chinese_Taiwan_Stroke_CI_AS
        , TRY_CONVERT(NUMERIC(5,0), s.source_item);

    CREATE TABLE #VendorCandidate
    (
          SourceOrder NVARCHAR(40)
              COLLATE Chinese_Taiwan_Stroke_CI_AS NOT NULL
        , SourceItem  NUMERIC(5,0) NOT NULL
        , VendorItemNo NVARCHAR(100) NULL
        , VendorId     NVARCHAR(100) NULL
        , BrandId      NVARCHAR(500) NULL
        , PriorityNo   TINYINT NOT NULL
    );

    /*
      4GL q001_pmm_pmn_p：
      RVV/RVB → PMN/Pmm
      PMN06  = 廠商料件編號
      PMM09  = 廠商ID
      PMN123 = 廠牌
    */

    /* RVV：rvv01 + rvv02 */
    INSERT INTO #VendorCandidate
    (
          SourceOrder
        , SourceItem
        , VendorItemNo
        , VendorId
        , BrandId
        , PriorityNo
    )
    SELECT
          sp.SourceOrder
        , sp.SourceItem
        , NULLIF(LTRIM(RTRIM(CONVERT(NVARCHAR(100), pmn.pmn06))), N'')
        , NULLIF(LTRIM(RTRIM(CONVERT(NVARCHAR(100), pmm.pmm09))), N'')
        , NULLIF(LTRIM(RTRIM(CONVERT(NVARCHAR(500), pmn.pmn123))), N'')
        , 1
    FROM #SourcePair AS sp
    INNER JOIN ERP_Staging.dbo.snx_rvv_file AS rvv
        ON rvv.rvv01 = sp.SourceOrder
       AND rvv.rvv02 = sp.SourceItem
    INNER JOIN ERP_Staging.dbo.snx_pmn_file AS pmn
        ON pmn.pmn01 = rvv.rvv36
       AND pmn.pmn02 = rvv.rvv37
    INNER JOIN ERP_Staging.dbo.snx_pmm_file AS pmm
        ON pmm.pmm01 = pmn.pmn01;

    /* RVV：rvv04 + rvv05 */
    INSERT INTO #VendorCandidate
    (
          SourceOrder
        , SourceItem
        , VendorItemNo
        , VendorId
        , BrandId
        , PriorityNo
    )
    SELECT
          sp.SourceOrder
        , sp.SourceItem
        , NULLIF(LTRIM(RTRIM(CONVERT(NVARCHAR(100), pmn.pmn06))), N'')
        , NULLIF(LTRIM(RTRIM(CONVERT(NVARCHAR(100), pmm.pmm09))), N'')
        , NULLIF(LTRIM(RTRIM(CONVERT(NVARCHAR(500), pmn.pmn123))), N'')
        , 2
    FROM #SourcePair AS sp
    INNER JOIN ERP_Staging.dbo.snx_rvv_file AS rvv
        ON rvv.rvv04 = sp.SourceOrder
       AND rvv.rvv05 = sp.SourceItem
    INNER JOIN ERP_Staging.dbo.snx_pmn_file AS pmn
        ON pmn.pmn01 = rvv.rvv36
       AND pmn.pmn02 = rvv.rvv37
    INNER JOIN ERP_Staging.dbo.snx_pmm_file AS pmm
        ON pmm.pmm01 = pmn.pmn01;

    /* RVB */
    INSERT INTO #VendorCandidate
    (
          SourceOrder
        , SourceItem
        , VendorItemNo
        , VendorId
        , BrandId
        , PriorityNo
    )
    SELECT
          sp.SourceOrder
        , sp.SourceItem
        , NULLIF(LTRIM(RTRIM(CONVERT(NVARCHAR(100), pmn.pmn06))), N'')
        , NULLIF(LTRIM(RTRIM(CONVERT(NVARCHAR(100), pmm.pmm09))), N'')
        , NULLIF(LTRIM(RTRIM(CONVERT(NVARCHAR(500), pmn.pmn123))), N'')
        , 3
    FROM #SourcePair AS sp
    INNER JOIN ERP_Staging.dbo.snx_rvb_file AS rvb
        ON rvb.rvb01 = sp.SourceOrder
       AND rvb.rvb02 = sp.SourceItem
    INNER JOIN ERP_Staging.dbo.snx_pmn_file AS pmn
        ON pmn.pmn01 = rvb.rvb04
       AND pmn.pmn02 = rvb.rvb03
    INNER JOIN ERP_Staging.dbo.snx_pmm_file AS pmm
        ON pmm.pmm01 = pmn.pmn01;

    /*
      4GL 雜收來源：
      ta_inb14 = 廠商料件編號
      ta_inb15 = 廠商ID
      ta_inb16 = 廠牌
    */
    INSERT INTO #VendorCandidate
    (
          SourceOrder
        , SourceItem
        , VendorItemNo
        , VendorId
        , BrandId
        , PriorityNo
    )
    SELECT
          sp.SourceOrder
        , sp.SourceItem
        , NULLIF(LTRIM(RTRIM(CONVERT(NVARCHAR(100), i.ta_inb14))), N'')
        , NULLIF(LTRIM(RTRIM(CONVERT(NVARCHAR(100), i.ta_inb15))), N'')
        , NULLIF(LTRIM(RTRIM(CONVERT(NVARCHAR(500), i.ta_inb16))), N'')
        , 4
    FROM #SourcePair AS sp
    INNER JOIN ERP_Staging.dbo.snx_inb_file AS i
        ON i.inb01 = sp.SourceOrder
       AND i.inb03 = sp.SourceItem;

    CREATE NONCLUSTERED INDEX IX_VendorCandidate_Key
        ON #VendorCandidate(SourceOrder, SourceItem, PriorityNo);

    ;WITH Ranked AS
    (
        SELECT
              c.SourceOrder
            , c.SourceItem
            , c.VendorItemNo
            , c.VendorId
            , c.BrandId
            , ROW_NUMBER() OVER
              (
                  PARTITION BY c.SourceOrder, c.SourceItem
                  ORDER BY
                        c.PriorityNo
                      , CASE WHEN c.VendorId IS NULL THEN 1 ELSE 0 END
                      , c.VendorId
                      , c.VendorItemNo
                      , c.BrandId
              ) AS rn
        FROM #VendorCandidate AS c
    )
    SELECT
          SourceOrder
        , SourceItem
        , VendorItemNo
        , VendorId
        , BrandId
    INTO #VendorBest
    FROM Ranked
    WHERE rn = 1;

    CREATE UNIQUE CLUSTERED INDEX IX_VendorBest_Key
        ON #VendorBest(SourceOrder, SourceItem);

    /*
      先整理為每個 InventoryKey 一筆，再回寫 #SnapshotLoad，
      避免主查詢被廠商來源表放大。
    */
    SELECT
          s.InventoryKey
        , vb.VendorItemNo
        , COALESCE
          (
              vb.VendorId,
              NULLIF
              (
                  LTRIM(RTRIM(CONVERT(NVARCHAR(100), rvbs_fb.tc_rvbs18))),
                  N''
              )
          ) AS VendorId
        , vb.BrandId
    INTO #VendorResolved
    FROM #SnapshotLoad AS s
    LEFT JOIN #VendorBest AS vb
        ON vb.SourceOrder =
           CONVERT(NVARCHAR(40), s.source_order)
              COLLATE Chinese_Taiwan_Stroke_CI_AS
       AND vb.SourceItem =
           TRY_CONVERT(NUMERIC(5,0), s.source_item)
    OUTER APPLY
    (
        SELECT TOP (1)
            r.tc_rvbs18
        FROM ERP_Staging.dbo.snx_tc_rvbs_file AS r
        WHERE r.tc_rvbs01 =
              CONVERT(NVARCHAR(40), s.imgs01)
                  COLLATE Chinese_Taiwan_Stroke_CI_AS
          AND r.tc_rvbs02 =
              CONVERT(NVARCHAR(40), s.imgs04)
                  COLLATE Chinese_Taiwan_Stroke_CI_AS
          AND r.tc_rvbs03 =
              CONVERT(NVARCHAR(40), s.imgs06)
                  COLLATE Chinese_Taiwan_Stroke_CI_AS
        ORDER BY r.tc_rvbs18
    ) AS rvbs_fb;

    CREATE UNIQUE CLUSTERED INDEX IX_VendorResolved_InventoryKey
        ON #VendorResolved(InventoryKey);

    UPDATE s
       SET s.pmn06    = vr.VendorItemNo,
           s.pmc01    = vr.VendorId,
           s.pmc03    = pmc.pmc03,
           s.ta_ima39 = vr.BrandId,
           s.mse02    = mse.mse02
    FROM #SnapshotLoad AS s
    INNER JOIN #VendorResolved AS vr
        ON vr.InventoryKey = s.InventoryKey
    LEFT JOIN ERP_Staging.dbo.snx_pmc_file AS pmc
        ON pmc.pmc01 =
           CONVERT(NVARCHAR(40), vr.VendorId)
              COLLATE Chinese_Taiwan_Stroke_CI_AS
    LEFT JOIN ERP_Staging.dbo.snx_mse_file AS mse
        ON mse.mse01 =
           CONVERT(NVARCHAR(40), vr.BrandId)
              COLLATE Chinese_Taiwan_Stroke_CI_AS;

    BEGIN TRY
        BEGIN TRANSACTION;

        /*
          #SnapshotLoad 完成後才更新正式表。
          三營運中心架構下只清除 SNX 舊快照，
          保留 GFUN / M302 資料。
        */
        DELETE FROM dbo.InventoryInquirySnapshot
        WHERE OperatingCenter = N'SNX';

        INSERT INTO dbo.InventoryInquirySnapshot
        (
            InventoryKey,
            OperatingCenter,
            LoadBatchId,
            SnapshotTime,
            sel,
            [zero],
            tc_imv01,
            imgs01,
            ima02,
            ta_ima158,
            ima021,
            imgs02,
            imd02,
            imgs03,
            ime03,
            imgs04,
            imgs06,
            imgs06_desc,
            imgs05,
            imgs05_desc,
            imgs09,
            imgs08,
            imgs07,
            att01,
            att02,
            tc_bmz11,
            tc_rvbs22,
            tc_rvbs23,
            tc_rvbs24,
            tc_rvbs24_desc,
            tc_rvbs25,
            tc_rvbs25_desc,
            att03,
            att04,
            att05,
            att06,
            att07,
            att08,
            att09,
            att10,
            att01_code,
            att01_name,
            att02_code,
            att02_name,
            att03_code,
            att03_name,
            att04_code,
            att04_name,
            att05_code,
            att05_name,
            att06_code,
            att06_name,
            att07_code,
            att07_name,
            att08_code,
            att08_name,
            att09_code,
            att09_name,
            att10_code,
            att10_name,
            pmm01,
            tc_oad03,
            ta_oea01_b,
            occ02,
            ta_sfb05,
            ta_sfb04,
            ta_sfb06,
            ta_sfb38,
            pmn06,
            pmc01,
            pmc03,
            ta_ima39,
            mse02,
            ta_ima91,
            ta_oea05_b,
            oeb70d,
            oea14,
            oea14_desc,
            oea15,
            oea15_desc,
            ta_imgs01,
            ta_imgs01_d,
            ta_imgs02,
            ta_imgs02_d,
            sfu16,
            sfu16_desc,
            oeaud04,
            oeb15,
            prepare,
            ccc23,
            source_order,
            source_item,
            sales_order_item,
            grade,
            receive_cloth_no,
            vendor_item_no,
            inventory_memo,
            ta_ima01,
            ta_ima20,
            ta_ima84,
            ta_oea11
        )
        SELECT
            InventoryKey,
            N'SNX' AS OperatingCenter,
            LoadBatchId,
            SnapshotTime,
            sel,
            [zero],
            tc_imv01,
            imgs01,
            ima02,
            ta_ima158,
            ima021,
            imgs02,
            imd02,
            imgs03,
            ime03,
            imgs04,
            imgs06,
            imgs06_desc,
            imgs05,
            imgs05_desc,
            imgs09,
            imgs08,
            imgs07,
            att01,
            att02,
            tc_bmz11,
            tc_rvbs22,
            tc_rvbs23,
            tc_rvbs24,
            tc_rvbs24_desc,
            tc_rvbs25,
            tc_rvbs25_desc,
            att03,
            att04,
            att05,
            att06,
            att07,
            att08,
            att09,
            att10,
            att01_code,
            att01_name,
            att02_code,
            att02_name,
            att03_code,
            att03_name,
            att04_code,
            att04_name,
            att05_code,
            att05_name,
            att06_code,
            att06_name,
            att07_code,
            att07_name,
            att08_code,
            att08_name,
            att09_code,
            att09_name,
            att10_code,
            att10_name,
            pmm01,
            tc_oad03,
            ta_oea01_b,
            occ02,
            ta_sfb05,
            ta_sfb04,
            ta_sfb06,
            ta_sfb38,
            pmn06,
            pmc01,
            pmc03,
            ta_ima39,
            mse02,
            ta_ima91,
            ta_oea05_b,
            oeb70d,
            oea14,
            oea14_desc,
            oea15,
            oea15_desc,
            ta_imgs01,
            ta_imgs01_d,
            ta_imgs02,
            ta_imgs02_d,
            sfu16,
            sfu16_desc,
            oeaud04,
            oeb15,
            prepare,
            ccc23,
            source_order,
            source_item,
            sales_order_item,
            grade,
            receive_cloth_no,
            vendor_item_no,
            inventory_memo,
            ta_ima01,
            ta_ima20,
            ta_ima84,
            ta_oea11
        FROM #SnapshotLoad;

        SET @InsertedRows = @@ROWCOUNT;

        COMMIT TRANSACTION;

        /*
          顯示本次載入結果，並保留重複鍵診斷。
        */
        SELECT
            @InsertedRows AS InsertedRows,
            (
                SELECT COUNT(DISTINCT InventoryKey)
                FROM dbo.InventoryInquirySnapshot
            ) AS DistinctInventoryKeys,
            (
                SELECT COUNT(*)
                FROM
                (
                    SELECT InventoryKey
                    FROM dbo.InventoryInquirySnapshot
                    GROUP BY InventoryKey
                    HAVING COUNT(*) > 1
                ) AS DuplicateKeys
            ) AS DuplicateInventoryKeyGroups,
            @LoadBatchId AS LoadBatchId,
            @SnapshotTime AS SnapshotTime;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0
            ROLLBACK TRANSACTION;

        THROW;
    END CATCH;
END;

GO
