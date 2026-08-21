USE [SAL_MRT];
GO


/*
===============================================================================
步驟 10：修改查詢 SP，補入：
  1. 異動日期
  2. 異動日期起
  3. 異動日期迄
  4. 計算基準日
  5. att01～att10 的代碼、名稱、值
  6. 來源單號、來源項次、訂單項次、等級、收布編號、廠商料號、備註

本步驟只修改 dbo.sp_Query_InventoryInquiry，不執行 SP。
===============================================================================
*/

CREATE   PROCEDURE dbo.sp_Query_InventoryInquiry
(
      @BeginDate           DATE
    , @EndDate             DATE
    , @CalculationBaseDate DATE = NULL

    , @ta_ima01            NVARCHAR(100) = NULL
    , @ta_ima20            NVARCHAR(100) = NULL
    , @ta_oea11            NVARCHAR(100) = NULL

    , @imgs01              NVARCHAR(100) = NULL
    , @imgs02              NVARCHAR(100) = NULL
    , @imgs03              NVARCHAR(100) = NULL
    , @imgs04              NVARCHAR(100) = NULL
    , @imgs05              NVARCHAR(100) = NULL
    , @imgs06              NVARCHAR(100) = NULL

    , @ta_imgs01           NVARCHAR(100) = NULL
    , @ta_imgs02           NVARCHAR(100) = NULL
)
AS
BEGIN
    SET NOCOUNT ON;

    IF @BeginDate IS NULL OR @EndDate IS NULL
    BEGIN
        THROW 50001, N'異動開始日期與異動結束日期均為必填。', 1;
    END;

    IF @EndDate < @BeginDate
    BEGIN
        THROW 50002, N'異動結束日期不可小於異動開始日期。', 1;
    END;

    DECLARE
          @p_ta_ima01  NVARCHAR(100) = NULLIF(LTRIM(RTRIM(@ta_ima01)),  N'')
        , @p_ta_ima20  NVARCHAR(100) = NULLIF(LTRIM(RTRIM(@ta_ima20)),  N'')
        , @p_ta_oea11  NVARCHAR(100) = NULLIF(LTRIM(RTRIM(@ta_oea11)),  N'')

        , @p_imgs01    NVARCHAR(100) = NULLIF(LTRIM(RTRIM(@imgs01)),    N'')
        , @p_imgs02    NVARCHAR(100) = NULLIF(LTRIM(RTRIM(@imgs02)),    N'')
        , @p_imgs03    NVARCHAR(100) = NULLIF(LTRIM(RTRIM(@imgs03)),    N'')
        , @p_imgs04    NVARCHAR(100) = NULLIF(LTRIM(RTRIM(@imgs04)),    N'')
        , @p_imgs05    NVARCHAR(100) = NULLIF(LTRIM(RTRIM(@imgs05)),    N'')
        , @p_imgs06    NVARCHAR(100) = NULLIF(LTRIM(RTRIM(@imgs06)),    N'')

        , @p_ta_imgs01 NVARCHAR(100) = NULLIF(LTRIM(RTRIM(@ta_imgs01)), N'')
        , @p_ta_imgs02 NVARCHAR(100) = NULLIF(LTRIM(RTRIM(@ta_imgs02)), N'');

    DECLARE @SelectList NVARCHAR(MAX) = N'
          s.tc_imv01 AS [零元專案否]
        , s.imgs01 AS [料號]
        , s.ima02 AS [品名]
        , s.ta_ima158 AS [Tranzend上架品名]
        , s.ima021 AS [規格]
        , s.imgs02 AS [倉庫]
        , s.imd02 AS [倉庫名稱]
        , s.imgs03 AS [儲位]
        , s.ime03 AS [儲位名稱]
        , s.imgs04 AS [批號(訂單/請購單)]
        , s.imgs06 AS [製造批號(顏色)]
        , s.imgs06_desc AS [顏色說明]
        , s.imgs05 AS [序號(尺寸)]
        , s.imgs05_desc AS [尺寸說明]
        , s.imgs09 AS [入庫日期]
        , s.imgs08 AS [數量]
        , s.imgs07 AS [單位]
        , s.tc_bmz11 AS [興采胚布批號]
        , s.tc_rvbs22 AS [布疋號]
        , s.tc_rvbs23 AS [含漿否]
        , s.tc_rvbs24 AS [限定染色]
        , s.tc_rvbs24_desc AS [限定染色名稱]
        , s.tc_rvbs25 AS [限定染色原因]
        , s.tc_rvbs25_desc AS [限定染色原因名稱]
        , s.pmm01 AS [採購單號]
        , s.tc_oad03 AS [訂單類別]
        , s.ta_oea01_b AS [Final Buyer ID]
        , s.occ02 AS [Final Buyer名稱]';

    /* 保留原本依類型控制固定欄位顯示的邏輯 */
    IF @p_ta_ima01 IS NULL OR @p_ta_ima01 <> N'4'
    BEGIN
        SET @SelectList += N'
        , s.ta_sfb05 AS [中文色名]
        , s.ta_sfb04 AS [英文色名]';
    END;

    IF @p_ta_ima01 IS NULL OR @p_ta_ima01 NOT IN (N'2', N'4')
    BEGIN
        SET @SelectList += N'
        , s.ta_sfb06 AS [興采色號]
        , s.ta_sfb38 AS [外廠色號]';
    END;

    IF @p_ta_ima01 IS NULL OR @p_ta_ima01 NOT IN (N'1', N'8', N'9')
    BEGIN
        SET @SelectList += N'
        , s.pmn06 AS [廠商料件編號]';
    END;

    SET @SelectList += N'
        , s.pmc01 AS [廠商ID]
        , s.pmc03 AS [廠商簡稱]';

    IF @p_ta_ima01 IS NULL
       OR @p_ta_ima01 NOT IN (N'1', N'2', N'4', N'8', N'9')
    BEGIN
        SET @SelectList += N'
        , s.ta_ima39 AS [廠牌]
        , s.mse02 AS [廠牌名稱]';
    END;

    IF @p_ta_ima01 IS NULL
       OR @p_ta_ima01 NOT IN (N'1', N'2', N'3', N'8', N'9')
    BEGIN
        SET @SelectList += N'
        , s.ta_ima91 AS [織軸類別]';
    END;

    IF @p_ta_ima01 IS NULL OR @p_ta_ima01 <> N'4'
    BEGIN
        SET @SelectList += N'
        , s.ta_oea05_b AS [訂單結案]';
    END;

    SET @SelectList += N'
        , s.oeb70d AS [結案日期]
        , s.oea14 AS [業務]
        , s.oea14_desc AS [業務姓名]
        , s.oea15 AS [業務部門]
        , s.oea15_desc AS [業務部門簡稱]
        , s.ta_imgs01 AS [理由碼]
        , s.ta_imgs01_d AS [理由碼說明]
        , s.ta_imgs02 AS [庫存歸屬部門]
        , s.ta_imgs02_d AS [庫存歸屬部門說明]
        , s.sfu16 AS [生管/採購人員]
        , s.sfu16_desc AS [生管/採購人員姓名]
        , s.oeaud04 AS [PI舊單號]
        , s.oeb15 AS [訂單客戶交期]
        , s.prepare AS [計畫性備產否]
        , s.ccc23 AS [平均成本]

        , s.att01_code AS [att01代碼]
        , s.att01_name AS [att01名稱]
        , s.att01 AS [att01值]
        , s.att02_code AS [att02代碼]
        , s.att02_name AS [att02名稱]
        , s.att02 AS [att02值]
        , s.att03_code AS [att03代碼]
        , s.att03_name AS [att03名稱]
        , s.att03 AS [att03值]
        , s.att04_code AS [att04代碼]
        , s.att04_name AS [att04名稱]
        , s.att04 AS [att04值]
        , s.att05_code AS [att05代碼]
        , s.att05_name AS [att05名稱]
        , s.att05 AS [att05值]
        , s.att06_code AS [att06代碼]
        , s.att06_name AS [att06名稱]
        , s.att06 AS [att06值]
        , s.att07_code AS [att07代碼]
        , s.att07_name AS [att07名稱]
        , s.att07 AS [att07值]
        , s.att08_code AS [att08代碼]
        , s.att08_name AS [att08名稱]
        , s.att08 AS [att08值]
        , s.att09_code AS [att09代碼]
        , s.att09_name AS [att09名稱]
        , s.att09 AS [att09值]
        , s.att10_code AS [att10代碼]
        , s.att10_name AS [att10名稱]
        , s.att10 AS [att10值]

        , s.source_order AS [來源單號]
        , s.source_item AS [來源項次]
        , s.sales_order_item AS [訂單項次]
        , s.grade AS [等級]
        , s.receive_cloth_no AS [收布編號]
        , s.vendor_item_no AS [廠商料號]
        , s.inventory_memo AS [備註]

        , act.ActivityDate AS [異動日期]
        , @BeginDate AS [異動日期起]
        , @EndDate AS [異動日期迄]
        , @CalculationBaseDate AS [計算基準日]';

    DECLARE @Sql NVARCHAR(MAX) = N'
    SELECT
        ' + @SelectList + N'
    FROM dbo.InventoryInquirySnapshot AS s

    CROSS APPLY
    (
        SELECT MAX(a.ActivityDate) AS ActivityDate
        FROM dbo.InventoryInquiryActivity AS a
        WHERE a.InventoryKey = s.InventoryKey
          AND a.ActivityType = N''TLFS''
          AND a.ActivityDate >= @BeginDate
          AND a.ActivityDate <= @EndDate
    ) AS act

    WHERE act.ActivityDate IS NOT NULL

        AND
        (
            @p_ta_ima01 IS NULL
            OR s.ta_ima01 COLLATE Latin1_General_100_BIN2
               = @p_ta_ima01 COLLATE Latin1_General_100_BIN2
        )

        AND
        (
            @p_ta_ima20 IS NULL
            OR s.ta_ima20 COLLATE Latin1_General_100_BIN2
               = @p_ta_ima20 COLLATE Latin1_General_100_BIN2
        )

        AND
        (
            @p_ta_oea11 IS NULL
            OR s.ta_oea11 COLLATE Latin1_General_100_BIN2
               = @p_ta_oea11 COLLATE Latin1_General_100_BIN2
        )

        AND
        (
            @p_imgs01 IS NULL
            OR s.imgs01 COLLATE Latin1_General_100_BIN2
               = @p_imgs01 COLLATE Latin1_General_100_BIN2
        )

        AND
        (
            @p_imgs02 IS NULL
            OR s.imgs02 COLLATE Latin1_General_100_BIN2
               = @p_imgs02 COLLATE Latin1_General_100_BIN2
        )

        AND
        (
            @p_imgs03 IS NULL
            OR s.imgs03 COLLATE Latin1_General_100_BIN2
               = @p_imgs03 COLLATE Latin1_General_100_BIN2
        )

        AND
        (
            @p_imgs04 IS NULL
            OR s.imgs04 COLLATE Latin1_General_100_BIN2
               = @p_imgs04 COLLATE Latin1_General_100_BIN2
        )

        AND
        (
            @p_imgs05 IS NULL
            OR s.imgs05 COLLATE Latin1_General_100_BIN2
               = @p_imgs05 COLLATE Latin1_General_100_BIN2
        )

        AND
        (
            @p_imgs06 IS NULL
            OR s.imgs06 COLLATE Latin1_General_100_BIN2
               = @p_imgs06 COLLATE Latin1_General_100_BIN2
        )

        AND
        (
            @p_ta_imgs01 IS NULL
            OR s.ta_imgs01 COLLATE Latin1_General_100_BIN2
               = @p_ta_imgs01 COLLATE Latin1_General_100_BIN2
        )

        AND
        (
            @p_ta_imgs02 IS NULL
            OR s.ta_imgs02 COLLATE Latin1_General_100_BIN2
               = @p_ta_imgs02 COLLATE Latin1_General_100_BIN2
        )

    ORDER BY
          s.imgs01
        , s.imgs02
        , s.imgs03
        , s.imgs04
        , s.imgs06

    OPTION (RECOMPILE);';

    EXEC sys.sp_executesql
          @Sql
        , N'
              @BeginDate           DATE
            , @EndDate             DATE
            , @CalculationBaseDate DATE
            , @p_ta_ima01          NVARCHAR(100)
            , @p_ta_ima20          NVARCHAR(100)
            , @p_ta_oea11          NVARCHAR(100)
            , @p_imgs01            NVARCHAR(100)
            , @p_imgs02            NVARCHAR(100)
            , @p_imgs03            NVARCHAR(100)
            , @p_imgs04            NVARCHAR(100)
            , @p_imgs05            NVARCHAR(100)
            , @p_imgs06            NVARCHAR(100)
            , @p_ta_imgs01         NVARCHAR(100)
            , @p_ta_imgs02         NVARCHAR(100)
          '
        , @BeginDate           = @BeginDate
        , @EndDate             = @EndDate
        , @CalculationBaseDate = @CalculationBaseDate
        , @p_ta_ima01          = @p_ta_ima01
        , @p_ta_ima20          = @p_ta_ima20
        , @p_ta_oea11          = @p_ta_oea11
        , @p_imgs01            = @p_imgs01
        , @p_imgs02            = @p_imgs02
        , @p_imgs03            = @p_imgs03
        , @p_imgs04            = @p_imgs04
        , @p_imgs05            = @p_imgs05
        , @p_imgs06            = @p_imgs06
        , @p_ta_imgs01         = @p_ta_imgs01
        , @p_ta_imgs02         = @p_ta_imgs02;
END;

GO
