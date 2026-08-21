USE [SAL_MRT];
GO



/*
===============================================================================
dbo.sp_Update_InventoryInquiryZeroFlag
===============================================================================
VERSION: ZEROFLAG_V5_OPERATING_CENTER_M302

修正重點：
  1. 完全移除動態 SQL、@LocalSql、sp_executesql。
  2. 興采、GFUN 與 M302 先載入相同結構的暫存表，再以一段固定 SQL 計算。
  3. tc_imv01 是 SKU；InventoryInquirySnapshot.[zero] 才是零元專案否。
  4. 只更新既有 InventoryInquirySnapshot，不重載庫存、不修改成本與異動紀錄。

輸出：
  [zero] = Y：已符合 100% 提列規則
  [zero] = N：未符合 100% 提列規則
===============================================================================
*/
CREATE   PROCEDURE dbo.sp_Update_InventoryInquiryZeroFlag
      @CalculationBaseDate DATE = NULL
    , @IncludeSNX          BIT  = 1
    , @IncludeGFUN         BIT  = 1
    , @IncludeM302         BIT  = 0
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    /* VERSION: ZEROFLAG_V5_OPERATING_CENTER_M302 */

    DECLARE
          @StartedAt   DATETIME2(0) = SYSDATETIME()
        , @CompletedAt DATETIME2(0)
        , @LockResult  INT
        , @ResetRows   BIGINT = 0
        , @MarkedRows  BIGINT = 0;

    EXEC @LockResult = sys.sp_getapplock
          @Resource = N'SAL_MRT.InventoryInquiry.ZeroFlag'
        , @LockMode = N'Exclusive'
        , @LockOwner = N'Session'
        , @LockTimeout = 0;

    IF @LockResult < 0
    BEGIN
        THROW 50001, N'零元專案／100% 提列判斷目前正在執行中。', 1;
    END;

    BEGIN TRY
        /*========================================================
          1. 基本檢查
        ========================================================*/
        IF OBJECT_ID(N'dbo.InventoryInquirySnapshot', N'U') IS NULL
        BEGIN
            THROW 50002, N'dbo.InventoryInquirySnapshot 資料表不存在。', 1;
        END;

        IF COL_LENGTH(N'dbo.InventoryInquirySnapshot', N'zero') IS NULL
        BEGIN
            THROW 50003, N'dbo.InventoryInquirySnapshot 缺少 zero 欄位。', 1;
        END;

        IF COL_LENGTH(N'dbo.InventoryInquirySnapshot', N'OperatingCenter') IS NULL
        BEGIN
            THROW 50007, N'dbo.InventoryInquirySnapshot 缺少 OperatingCenter 欄位。', 1;
        END;

        IF NOT EXISTS
        (
            SELECT 1
            FROM dbo.InventoryInquirySnapshot
        )
        BEGIN
            THROW 50004,
                  N'InventoryInquirySnapshot 尚無資料，請先執行核心庫存載入 SP。',
                  1;
        END;

        IF ISNULL(@IncludeSNX, 0) = 0
           AND ISNULL(@IncludeGFUN, 0) = 0
           AND ISNULL(@IncludeM302, 0) = 0
        BEGIN
            THROW 50005, N'@IncludeSNX、@IncludeGFUN、@IncludeM302 不可同時為 0。', 1;
        END;

        IF @IncludeSNX = 1
        BEGIN
            IF OBJECT_ID(N'ERP_Staging.dbo.snx_ima_file', N'U') IS NULL
                THROW 50011, N'缺少 ERP_Staging.dbo.snx_ima_file。', 1;
            IF OBJECT_ID(N'ERP_Staging.dbo.snx_imgs_file', N'U') IS NULL
                THROW 50012, N'缺少 ERP_Staging.dbo.snx_imgs_file。', 1;
            IF OBJECT_ID(N'ERP_Staging.dbo.snx_tc_cmc_file', N'U') IS NULL
                THROW 50013, N'缺少 ERP_Staging.dbo.snx_tc_cmc_file。', 1;
            IF OBJECT_ID(N'ERP_Staging.dbo.snx_tc_cmcc_file', N'U') IS NULL
                THROW 50014, N'缺少 ERP_Staging.dbo.snx_tc_cmcc_file。', 1;
            IF OBJECT_ID(N'ERP_Staging.dbo.snx_tc_cmz_file', N'U') IS NULL
                THROW 50015, N'缺少 ERP_Staging.dbo.snx_tc_cmz_file。', 1;
            IF OBJECT_ID(N'ERP_Staging.dbo.snx_agd_file', N'U') IS NULL
                THROW 50016, N'缺少 ERP_Staging.dbo.snx_agd_file。', 1;
            IF OBJECT_ID(N'ERP_Staging.dbo.snx_jce_file', N'U') IS NULL
                THROW 50017, N'缺少 ERP_Staging.dbo.snx_jce_file。', 1;
            IF OBJECT_ID(N'ERP_Staging.dbo.snx_oea_file', N'U') IS NULL
                THROW 50018, N'缺少 ERP_Staging.dbo.snx_oea_file。', 1;
        END;

        IF @IncludeGFUN = 1
        BEGIN
            IF OBJECT_ID(N'ERP_Staging.dbo.ima_file', N'U') IS NULL
                THROW 50021, N'缺少 ERP_Staging.dbo.ima_file。', 1;
            IF OBJECT_ID(N'ERP_Staging.dbo.imgs_file', N'U') IS NULL
                THROW 50022, N'缺少 ERP_Staging.dbo.imgs_file。', 1;
            IF OBJECT_ID(N'ERP_Staging.dbo.tc_cmc_file', N'U') IS NULL
                THROW 50023, N'缺少 ERP_Staging.dbo.tc_cmc_file。', 1;
            IF OBJECT_ID(N'ERP_Staging.dbo.tc_cmcc_file', N'U') IS NULL
                THROW 50024, N'缺少 ERP_Staging.dbo.tc_cmcc_file。', 1;
            IF OBJECT_ID(N'ERP_Staging.dbo.tc_cmz_file', N'U') IS NULL
                THROW 50025, N'缺少 ERP_Staging.dbo.tc_cmz_file。', 1;
            IF OBJECT_ID(N'ERP_Staging.dbo.agd_file', N'U') IS NULL
                THROW 50026, N'缺少 ERP_Staging.dbo.agd_file。', 1;
            IF OBJECT_ID(N'ERP_Staging.dbo.jce_file', N'U') IS NULL
                THROW 50027, N'缺少 ERP_Staging.dbo.jce_file。', 1;
            IF OBJECT_ID(N'ERP_Staging.dbo.oea_file', N'U') IS NULL
                THROW 50028, N'缺少 ERP_Staging.dbo.oea_file。', 1;
        END;

        IF @IncludeM302 = 1
        BEGIN
            IF OBJECT_ID(N'ERP_Staging.dbo.m302_ima_file', N'U') IS NULL
                THROW 50031, N'缺少 ERP_Staging.dbo.m302_ima_file。', 1;
            IF OBJECT_ID(N'ERP_Staging.dbo.m302_imgs_file', N'U') IS NULL
                THROW 50032, N'缺少 ERP_Staging.dbo.m302_imgs_file。', 1;
            IF OBJECT_ID(N'ERP_Staging.dbo.m302_tc_cmc_file', N'U') IS NULL
                THROW 50033, N'缺少 ERP_Staging.dbo.m302_tc_cmc_file。', 1;
            IF OBJECT_ID(N'ERP_Staging.dbo.m302_tc_cmcc_file', N'U') IS NULL
                THROW 50034, N'缺少 ERP_Staging.dbo.m302_tc_cmcc_file。', 1;
            IF OBJECT_ID(N'ERP_Staging.dbo.m302_tc_cmz_file', N'U') IS NULL
                THROW 50035, N'缺少 ERP_Staging.dbo.m302_tc_cmz_file。', 1;
            IF OBJECT_ID(N'ERP_Staging.dbo.m302_agd_file', N'U') IS NULL
                THROW 50036, N'缺少 ERP_Staging.dbo.m302_agd_file。', 1;
            IF OBJECT_ID(N'ERP_Staging.dbo.m302_jce_file', N'U') IS NULL
                THROW 50037, N'缺少 ERP_Staging.dbo.m302_jce_file。', 1;
            IF OBJECT_ID(N'ERP_Staging.dbo.m302_oea_file', N'U') IS NULL
                THROW 50038, N'缺少 ERP_Staging.dbo.m302_oea_file。', 1;
        END;

        /*========================================================
          2. 計算期間
        ========================================================*/
        DROP TABLE IF EXISTS #Ccz;

        CREATE TABLE #Ccz
        (
              SourceCode NVARCHAR(20) NOT NULL
            , CczYear    INT          NULL
            , CczMonth   INT          NULL
            , BaseDate   DATE         NULL
        );

        IF @IncludeSNX = 1
        BEGIN
            INSERT INTO #Ccz
            (
                  SourceCode
                , CczYear
                , CczMonth
                , BaseDate
            )
            SELECT
                  N'SNX'
                , TRY_CONVERT(INT, CCZ01)
                , TRY_CONVERT(INT, CCZ02)
                , @CalculationBaseDate
            FROM OPENQUERY
            (
                [ORACLE_LINKED_SERVER],
                '
                    SELECT
                          ccz01
                        , ccz02
                    FROM snx_202012.ccz_file
                    WHERE ROWNUM = 1
                '
            );
        END;

        IF @IncludeGFUN = 1
        BEGIN
            INSERT INTO #Ccz
            (
                  SourceCode
                , CczYear
                , CczMonth
                , BaseDate
            )
            SELECT
                  N'GFUN'
                , TRY_CONVERT(INT, CCZ01)
                , TRY_CONVERT(INT, CCZ02)
                , @CalculationBaseDate
            FROM OPENQUERY
            (
                [ORACLE_LINKED_SERVER],
                '
                    SELECT
                          ccz01
                        , ccz02
                    FROM gfn_202210.ccz_file
                    WHERE ROWNUM = 1
                '
            );
        END;

        IF @IncludeM302 = 1
        BEGIN
            INSERT INTO #Ccz
            (
                  SourceCode
                , CczYear
                , CczMonth
                , BaseDate
            )
            SELECT
                  N'M302'
                , TRY_CONVERT(INT, CCZ01)
                , TRY_CONVERT(INT, CCZ02)
                , @CalculationBaseDate
            FROM OPENQUERY
            (
                [ORACLE_LINKED_SERVER],
                '
                    SELECT
                          ccz01
                        , ccz02
                    FROM M302_2023.ccz_file
                    WHERE ROWNUM = 1
                '
            );
        END;

        UPDATE #Ccz
        SET BaseDate =
            CASE
                WHEN BaseDate IS NOT NULL
                    THEN BaseDate
                WHEN CczYear BETWEEN 1900 AND 9999
                 AND CczMonth BETWEEN 1 AND 12
                    THEN EOMONTH(DATEFROMPARTS(CczYear, CczMonth, 1))
                ELSE NULL
            END;

        IF EXISTS
        (
            SELECT 1
            FROM #Ccz
            WHERE BaseDate IS NULL
        )
        BEGIN
            THROW 50006,
                  N'無法由 ccz_file 推算計算基準日，請指定 @CalculationBaseDate。',
                  1;
        END;

        /*========================================================
          3. 統一暫存表
        ========================================================*/
        DROP TABLE IF EXISTS #Ima;
        CREATE TABLE #Ima
        (
              SourceCode   NVARCHAR(20)  NOT NULL
            , ItemNo       NVARCHAR(100) COLLATE Latin1_General_100_BIN2 NOT NULL
            , ItemCategory NVARCHAR(100) NULL
            , Ima918       NVARCHAR(10)  NULL
            , Ima921       NVARCHAR(10)  NULL
            , Ima943       NVARCHAR(10)  NULL
        );

        DROP TABLE IF EXISTS #Imgs;
        CREATE TABLE #Imgs
        (
              SourceCode        NVARCHAR(20)  NOT NULL
            , ItemNo            NVARCHAR(100) COLLATE Latin1_General_100_BIN2 NOT NULL
            , WarehouseNo       NVARCHAR(50)  COLLATE Latin1_General_100_BIN2 NOT NULL
            , LocationNo        NVARCHAR(50)  COLLATE Latin1_General_100_BIN2 NOT NULL
            , LotNo             NVARCHAR(100) COLLATE Latin1_General_100_BIN2 NOT NULL
            , SerialNo          NVARCHAR(100) COLLATE Latin1_General_100_BIN2 NOT NULL
            , ManufacturingLotNo NVARCHAR(100) COLLATE Latin1_General_100_BIN2 NOT NULL
            , Imgs11            NVARCHAR(100) NULL
        );

        DROP TABLE IF EXISTS #Agd;
        CREATE TABLE #Agd
        (
              SourceCode NVARCHAR(20)  NOT NULL
            , ColorNo    NVARCHAR(100) COLLATE Latin1_General_100_BIN2 NOT NULL
        );

        DROP TABLE IF EXISTS #Oea;
        CREATE TABLE #Oea
        (
              SourceCode NVARCHAR(20)  NOT NULL
            , OrderNo    NVARCHAR(100) COLLATE Latin1_General_100_BIN2 NOT NULL
        );

        DROP TABLE IF EXISTS #Cmc;
        CREATE TABLE #Cmc
        (
              SourceCode  NVARCHAR(20)  NOT NULL
            , ItemNo      NVARCHAR(100) COLLATE Latin1_General_100_BIN2 NOT NULL
            , WarehouseNo NVARCHAR(50)  COLLATE Latin1_General_100_BIN2 NOT NULL
            , LocationNo  NVARCHAR(50)  COLLATE Latin1_General_100_BIN2 NOT NULL
            , LotNo       NVARCHAR(100) COLLATE Latin1_General_100_BIN2 NOT NULL
            , CczYear     INT           NULL
            , CczMonth    INT           NULL
            , AgeDate     DATE          NULL
        );

        DROP TABLE IF EXISTS #Cmcc;
        CREATE TABLE #Cmcc
        (
              SourceCode         NVARCHAR(20)  NOT NULL
            , ItemNo             NVARCHAR(100) COLLATE Latin1_General_100_BIN2 NOT NULL
            , WarehouseNo        NVARCHAR(50)  COLLATE Latin1_General_100_BIN2 NOT NULL
            , LocationNo         NVARCHAR(50)  COLLATE Latin1_General_100_BIN2 NOT NULL
            , LotNo              NVARCHAR(100) COLLATE Latin1_General_100_BIN2 NOT NULL
            , SerialNo           NVARCHAR(100) COLLATE Latin1_General_100_BIN2 NOT NULL
            , ManufacturingLotNo NVARCHAR(100) COLLATE Latin1_General_100_BIN2 NOT NULL
            , Imgs11             NVARCHAR(100) COLLATE Latin1_General_100_BIN2 NOT NULL
            , CczYear            INT           NULL
            , CczMonth           INT           NULL
            , AgeDate            DATE          NULL
        );

        DROP TABLE IF EXISTS #Cmz;
        CREATE TABLE #Cmz
        (
              SourceCode   NVARCHAR(20)  NOT NULL
            , ItemTypeCode NVARCHAR(50)  COLLATE Latin1_General_100_BIN2 NOT NULL
            , SpecialFlag  NVARCHAR(1)   COLLATE Latin1_General_100_BIN2 NOT NULL
            , ItemCategory NVARCHAR(100) COLLATE Latin1_General_100_BIN2 NULL
            , D1From       DECIMAL(28,6) NULL
            , D1To         DECIMAL(28,6) NULL
            , R1           DECIMAL(28,6) NULL
            , D2From       DECIMAL(28,6) NULL
            , D2To         DECIMAL(28,6) NULL
            , R2           DECIMAL(28,6) NULL
            , D3From       DECIMAL(28,6) NULL
            , D3To         DECIMAL(28,6) NULL
            , R3           DECIMAL(28,6) NULL
            , D4From       DECIMAL(28,6) NULL
            , D4To         DECIMAL(28,6) NULL
            , R4           DECIMAL(28,6) NULL
            , D5From       DECIMAL(28,6) NULL
            , D5To         DECIMAL(28,6) NULL
            , R5           DECIMAL(28,6) NULL
            , D6From       DECIMAL(28,6) NULL
            , R6           DECIMAL(28,6) NULL
        );

        DROP TABLE IF EXISTS #Jce;
        CREATE TABLE #Jce
        (
              SourceCode  NVARCHAR(20) NOT NULL
            , WarehouseNo NVARCHAR(50) COLLATE Latin1_General_100_BIN2 NOT NULL
        );

        DROP TABLE IF EXISTS #Grade;
        CREATE TABLE #Grade
        (
              SourceCode         NVARCHAR(20)  NOT NULL
            , ItemNo             NVARCHAR(100) COLLATE Latin1_General_100_BIN2 NOT NULL
            , ManufacturingLotNo NVARCHAR(100) COLLATE Latin1_General_100_BIN2 NOT NULL
            , ClassCode          NVARCHAR(100) NULL
        );

        /*========================================================
          4. 載入興采資料
        ========================================================*/
        IF @IncludeSNX = 1
        BEGIN
            INSERT INTO #Ima
            SELECT
                  N'SNX'
                , CONVERT(NVARCHAR(100), ima01)
                , CONVERT(NVARCHAR(100), ima06)
                , UPPER(LTRIM(RTRIM(CONVERT(NVARCHAR(10), ima918))))
                , UPPER(LTRIM(RTRIM(CONVERT(NVARCHAR(10), ima921))))
                , UPPER
                  (
                      LTRIM
                      (
                          RTRIM
                          (
                              ISNULL(CONVERT(NVARCHAR(10), ima943), N' ')
                          )
                      )
                  )
            FROM ERP_Staging.dbo.snx_ima_file
            WHERE ima01 IS NOT NULL;

            INSERT INTO #Imgs
            SELECT
                  N'SNX'
                , CONVERT(NVARCHAR(100), imgs01)
                , CONVERT(NVARCHAR(50), imgs02)
                , CONVERT(NVARCHAR(50), imgs03)
                , ISNULL(NULLIF(RTRIM(CONVERT(NVARCHAR(100), imgs04)), N''), N' ')
                , ISNULL(NULLIF(RTRIM(CONVERT(NVARCHAR(100), imgs05)), N''), N' ')
                , ISNULL(NULLIF(RTRIM(CONVERT(NVARCHAR(100), imgs06)), N''), N' ')
                , CONVERT(NVARCHAR(100), imgs11)
            FROM ERP_Staging.dbo.snx_imgs_file
            WHERE imgs01 IS NOT NULL;

            INSERT INTO #Agd
            SELECT DISTINCT
                  N'SNX'
                , CONVERT(NVARCHAR(100), agd02)
            FROM ERP_Staging.dbo.snx_agd_file
            WHERE agd02 IS NOT NULL;

            INSERT INTO #Oea
            SELECT DISTINCT
                  N'SNX'
                , CONVERT(NVARCHAR(100), oea01)
            FROM ERP_Staging.dbo.snx_oea_file
            WHERE oea01 IS NOT NULL;

            INSERT INTO #Cmc
            SELECT
                  N'SNX'
                , CONVERT(NVARCHAR(100), tc_cmc01)
                , CONVERT(NVARCHAR(50), tc_cmc09)
                , CONVERT(NVARCHAR(50), tc_cmc10)
                , ISNULL(NULLIF(RTRIM(CONVERT(NVARCHAR(100), tc_cmc08)), N''), N' ')
                , TRY_CONVERT(INT, tc_cmc021)
                , TRY_CONVERT(INT, tc_cmc022)
                , TRY_CONVERT(DATE, tc_cmc03)
            FROM ERP_Staging.dbo.snx_tc_cmc_file
            WHERE tc_cmc01 IS NOT NULL;

            INSERT INTO #Cmcc
            SELECT
                  N'SNX'
                , CONVERT(NVARCHAR(100), tc_cmcc01)
                , CONVERT(NVARCHAR(50), tc_cmcc09)
                , CONVERT(NVARCHAR(50), tc_cmcc10)
                , ISNULL(NULLIF(RTRIM(CONVERT(NVARCHAR(100), tc_cmcc08)), N''), N' ')
                , ISNULL(NULLIF(RTRIM(CONVERT(NVARCHAR(100), tc_cmcc11)), N''), N' ')
                , ISNULL(NULLIF(RTRIM(CONVERT(NVARCHAR(100), tc_cmcc12)), N''), N' ')
                , ISNULL(NULLIF(RTRIM(CONVERT(NVARCHAR(100), tc_cmcc13)), N''), N' ')
                , TRY_CONVERT(INT, tc_cmcc021)
                , TRY_CONVERT(INT, tc_cmcc022)
                , TRY_CONVERT(DATE, tc_cmcc03)
            FROM ERP_Staging.dbo.snx_tc_cmcc_file
            WHERE tc_cmcc01 IS NOT NULL;

            INSERT INTO #Cmz
            SELECT
                  N'SNX'
                , LTRIM(RTRIM(CONVERT(NVARCHAR(50), tc_cmz01)))
                , LTRIM(RTRIM(CONVERT(NVARCHAR(1), tc_cmz02)))
                , LTRIM(RTRIM(CONVERT(NVARCHAR(100), tc_cmz17)))
                , TRY_CONVERT(DECIMAL(28,6), tc_cmz03)
                , TRY_CONVERT(DECIMAL(28,6), tc_cmz04)
                , TRY_CONVERT(DECIMAL(28,6), tc_cmz05)
                , TRY_CONVERT(DECIMAL(28,6), tc_cmz06)
                , TRY_CONVERT(DECIMAL(28,6), tc_cmz07)
                , TRY_CONVERT(DECIMAL(28,6), tc_cmz08)
                , TRY_CONVERT(DECIMAL(28,6), tc_cmz09)
                , TRY_CONVERT(DECIMAL(28,6), tc_cmz10)
                , TRY_CONVERT(DECIMAL(28,6), tc_cmz11)
                , TRY_CONVERT(DECIMAL(28,6), tc_cmz12)
                , TRY_CONVERT(DECIMAL(28,6), tc_cmz13)
                , TRY_CONVERT(DECIMAL(28,6), tc_cmz14)
                , TRY_CONVERT(DECIMAL(28,6), tc_cmz18)
                , TRY_CONVERT(DECIMAL(28,6), tc_cmz19)
                , TRY_CONVERT(DECIMAL(28,6), tc_cmz20)
                , TRY_CONVERT(DECIMAL(28,6), tc_cmz15)
                , TRY_CONVERT(DECIMAL(28,6), tc_cmz16)
            FROM ERP_Staging.dbo.snx_tc_cmz_file
            WHERE tc_cmz01 IS NOT NULL;

            INSERT INTO #Jce
            SELECT DISTINCT
                  N'SNX'
                , CONVERT(NVARCHAR(50), jce02)
            FROM ERP_Staging.dbo.snx_jce_file
            WHERE jce02 IS NOT NULL;

            INSERT INTO #Grade
            (
                  SourceCode
                , ItemNo
                , ManufacturingLotNo
                , ClassCode
            )
            SELECT
                  N'SNX'
                , CONVERT(NVARCHAR(100), ITEM_NO)
                , CONVERT(NVARCHAR(100), MANUFACTURING_LOT_NO)
                , NULLIF
                  (
                      LTRIM(RTRIM(CONVERT(NVARCHAR(100), CLASS_CODE))),
                      N''
                  )
            FROM OPENQUERY
            (
                [ORACLE_LINKED_SERVER],
                '
                    SELECT
                          inj01 AS item_no
                        , inj02 AS manufacturing_lot_no
                        , MAX(TRIM(inj04)) AS class_code
                    FROM snx_202012.inj_file
                    WHERE inj03 = ''S008''
                    GROUP BY
                          inj01
                        , inj02
                '
            )
            WHERE ITEM_NO IS NOT NULL
              AND MANUFACTURING_LOT_NO IS NOT NULL;
        END;

        /*========================================================
          5. 載入 GFUN 資料
        ========================================================*/
        IF @IncludeGFUN = 1
        BEGIN
            INSERT INTO #Ima
            SELECT
                  N'GFUN'
                , CONVERT(NVARCHAR(100), ima01)
                , CONVERT(NVARCHAR(100), ima06)
                , UPPER(LTRIM(RTRIM(CONVERT(NVARCHAR(10), ima918))))
                , UPPER(LTRIM(RTRIM(CONVERT(NVARCHAR(10), ima921))))
                , UPPER
                  (
                      LTRIM
                      (
                          RTRIM
                          (
                              ISNULL(CONVERT(NVARCHAR(10), ima943), N' ')
                          )
                      )
                  )
            FROM ERP_Staging.dbo.ima_file
            WHERE ima01 IS NOT NULL;

            INSERT INTO #Imgs
            SELECT
                  N'GFUN'
                , CONVERT(NVARCHAR(100), imgs01)
                , CONVERT(NVARCHAR(50), imgs02)
                , CONVERT(NVARCHAR(50), imgs03)
                , ISNULL(NULLIF(RTRIM(CONVERT(NVARCHAR(100), imgs04)), N''), N' ')
                , ISNULL(NULLIF(RTRIM(CONVERT(NVARCHAR(100), imgs05)), N''), N' ')
                , ISNULL(NULLIF(RTRIM(CONVERT(NVARCHAR(100), imgs06)), N''), N' ')
                , CONVERT(NVARCHAR(100), imgs11)
            FROM ERP_Staging.dbo.imgs_file
            WHERE imgs01 IS NOT NULL;

            INSERT INTO #Agd
            SELECT DISTINCT
                  N'GFUN'
                , CONVERT(NVARCHAR(100), agd02)
            FROM ERP_Staging.dbo.agd_file
            WHERE agd02 IS NOT NULL;

            INSERT INTO #Oea
            SELECT DISTINCT
                  N'GFUN'
                , CONVERT(NVARCHAR(100), oea01)
            FROM ERP_Staging.dbo.oea_file
            WHERE oea01 IS NOT NULL;

            INSERT INTO #Cmc
            SELECT
                  N'GFUN'
                , CONVERT(NVARCHAR(100), tc_cmc01)
                , CONVERT(NVARCHAR(50), tc_cmc09)
                , CONVERT(NVARCHAR(50), tc_cmc10)
                , ISNULL(NULLIF(RTRIM(CONVERT(NVARCHAR(100), tc_cmc08)), N''), N' ')
                , TRY_CONVERT(INT, tc_cmc021)
                , TRY_CONVERT(INT, tc_cmc022)
                , TRY_CONVERT(DATE, tc_cmc03)
            FROM ERP_Staging.dbo.tc_cmc_file
            WHERE tc_cmc01 IS NOT NULL;

            INSERT INTO #Cmcc
            SELECT
                  N'GFUN'
                , CONVERT(NVARCHAR(100), tc_cmcc01)
                , CONVERT(NVARCHAR(50), tc_cmcc09)
                , CONVERT(NVARCHAR(50), tc_cmcc10)
                , ISNULL(NULLIF(RTRIM(CONVERT(NVARCHAR(100), tc_cmcc08)), N''), N' ')
                , ISNULL(NULLIF(RTRIM(CONVERT(NVARCHAR(100), tc_cmcc11)), N''), N' ')
                , ISNULL(NULLIF(RTRIM(CONVERT(NVARCHAR(100), tc_cmcc12)), N''), N' ')
                , ISNULL(NULLIF(RTRIM(CONVERT(NVARCHAR(100), tc_cmcc13)), N''), N' ')
                , TRY_CONVERT(INT, tc_cmcc021)
                , TRY_CONVERT(INT, tc_cmcc022)
                , TRY_CONVERT(DATE, tc_cmcc03)
            FROM ERP_Staging.dbo.tc_cmcc_file
            WHERE tc_cmcc01 IS NOT NULL;

            INSERT INTO #Cmz
            SELECT
                  N'GFUN'
                , LTRIM(RTRIM(CONVERT(NVARCHAR(50), tc_cmz01)))
                , LTRIM(RTRIM(CONVERT(NVARCHAR(1), tc_cmz02)))
                , LTRIM(RTRIM(CONVERT(NVARCHAR(100), tc_cmz17)))
                , TRY_CONVERT(DECIMAL(28,6), tc_cmz03)
                , TRY_CONVERT(DECIMAL(28,6), tc_cmz04)
                , TRY_CONVERT(DECIMAL(28,6), tc_cmz05)
                , TRY_CONVERT(DECIMAL(28,6), tc_cmz06)
                , TRY_CONVERT(DECIMAL(28,6), tc_cmz07)
                , TRY_CONVERT(DECIMAL(28,6), tc_cmz08)
                , TRY_CONVERT(DECIMAL(28,6), tc_cmz09)
                , TRY_CONVERT(DECIMAL(28,6), tc_cmz10)
                , TRY_CONVERT(DECIMAL(28,6), tc_cmz11)
                , TRY_CONVERT(DECIMAL(28,6), tc_cmz12)
                , TRY_CONVERT(DECIMAL(28,6), tc_cmz13)
                , TRY_CONVERT(DECIMAL(28,6), tc_cmz14)
                , TRY_CONVERT(DECIMAL(28,6), tc_cmz18)
                , TRY_CONVERT(DECIMAL(28,6), tc_cmz19)
                , TRY_CONVERT(DECIMAL(28,6), tc_cmz20)
                , TRY_CONVERT(DECIMAL(28,6), tc_cmz15)
                , TRY_CONVERT(DECIMAL(28,6), tc_cmz16)
            FROM ERP_Staging.dbo.tc_cmz_file
            WHERE tc_cmz01 IS NOT NULL;

            INSERT INTO #Jce
            SELECT DISTINCT
                  N'GFUN'
                , CONVERT(NVARCHAR(50), jce02)
            FROM ERP_Staging.dbo.jce_file
            WHERE jce02 IS NOT NULL;

            INSERT INTO #Grade
            (
                  SourceCode
                , ItemNo
                , ManufacturingLotNo
                , ClassCode
            )
            SELECT
                  N'GFUN'
                , CONVERT(NVARCHAR(100), ITEM_NO)
                , CONVERT(NVARCHAR(100), MANUFACTURING_LOT_NO)
                , NULLIF
                  (
                      LTRIM(RTRIM(CONVERT(NVARCHAR(100), CLASS_CODE))),
                      N''
                  )
            FROM OPENQUERY
            (
                [ORACLE_LINKED_SERVER],
                '
                    SELECT
                          inj01 AS item_no
                        , inj02 AS manufacturing_lot_no
                        , MAX(TRIM(inj04)) AS class_code
                    FROM gfn_202210.inj_file
                    WHERE inj03 = ''S008''
                    GROUP BY
                          inj01
                        , inj02
                '
            )
            WHERE ITEM_NO IS NOT NULL
              AND MANUFACTURING_LOT_NO IS NOT NULL;
        END;

        /*========================================================
          6. 載入 M302 資料
        ========================================================*/
        IF @IncludeM302 = 1
        BEGIN
            INSERT INTO #Ima
            SELECT
                  N'M302'
                , CONVERT(NVARCHAR(100), ima01)
                , CONVERT(NVARCHAR(100), ima06)
                , UPPER(LTRIM(RTRIM(CONVERT(NVARCHAR(10), ima918))))
                , UPPER(LTRIM(RTRIM(CONVERT(NVARCHAR(10), ima921))))
                , UPPER
                  (
                      LTRIM
                      (
                          RTRIM
                          (
                              ISNULL(CONVERT(NVARCHAR(10), ima943), N' ')
                          )
                      )
                  )
            FROM ERP_Staging.dbo.m302_ima_file
            WHERE ima01 IS NOT NULL;

            INSERT INTO #Imgs
            SELECT
                  N'M302'
                , CONVERT(NVARCHAR(100), imgs01)
                , CONVERT(NVARCHAR(50), imgs02)
                , CONVERT(NVARCHAR(50), imgs03)
                , ISNULL(NULLIF(RTRIM(CONVERT(NVARCHAR(100), imgs04)), N''), N' ')
                , ISNULL(NULLIF(RTRIM(CONVERT(NVARCHAR(100), imgs05)), N''), N' ')
                , ISNULL(NULLIF(RTRIM(CONVERT(NVARCHAR(100), imgs06)), N''), N' ')
                , CONVERT(NVARCHAR(100), imgs11)
            FROM ERP_Staging.dbo.m302_imgs_file
            WHERE imgs01 IS NOT NULL;

            INSERT INTO #Agd
            SELECT DISTINCT
                  N'M302'
                , CONVERT(NVARCHAR(100), agd02)
            FROM ERP_Staging.dbo.m302_agd_file
            WHERE agd02 IS NOT NULL;

            INSERT INTO #Oea
            SELECT DISTINCT
                  N'M302'
                , CONVERT(NVARCHAR(100), oea01)
            FROM ERP_Staging.dbo.m302_oea_file
            WHERE oea01 IS NOT NULL;

            INSERT INTO #Cmc
            SELECT
                  N'M302'
                , CONVERT(NVARCHAR(100), tc_cmc01)
                , CONVERT(NVARCHAR(50), tc_cmc09)
                , CONVERT(NVARCHAR(50), tc_cmc10)
                , ISNULL(NULLIF(RTRIM(CONVERT(NVARCHAR(100), tc_cmc08)), N''), N' ')
                , TRY_CONVERT(INT, tc_cmc021)
                , TRY_CONVERT(INT, tc_cmc022)
                , TRY_CONVERT(DATE, tc_cmc03)
            FROM ERP_Staging.dbo.m302_tc_cmc_file
            WHERE tc_cmc01 IS NOT NULL;

            INSERT INTO #Cmcc
            SELECT
                  N'M302'
                , CONVERT(NVARCHAR(100), tc_cmcc01)
                , CONVERT(NVARCHAR(50), tc_cmcc09)
                , CONVERT(NVARCHAR(50), tc_cmcc10)
                , ISNULL(NULLIF(RTRIM(CONVERT(NVARCHAR(100), tc_cmcc08)), N''), N' ')
                , ISNULL(NULLIF(RTRIM(CONVERT(NVARCHAR(100), tc_cmcc11)), N''), N' ')
                , ISNULL(NULLIF(RTRIM(CONVERT(NVARCHAR(100), tc_cmcc12)), N''), N' ')
                , ISNULL(NULLIF(RTRIM(CONVERT(NVARCHAR(100), tc_cmcc13)), N''), N' ')
                , TRY_CONVERT(INT, tc_cmcc021)
                , TRY_CONVERT(INT, tc_cmcc022)
                , TRY_CONVERT(DATE, tc_cmcc03)
            FROM ERP_Staging.dbo.m302_tc_cmcc_file
            WHERE tc_cmcc01 IS NOT NULL;

            INSERT INTO #Cmz
            SELECT
                  N'M302'
                , LTRIM(RTRIM(CONVERT(NVARCHAR(50), tc_cmz01)))
                , LTRIM(RTRIM(CONVERT(NVARCHAR(1), tc_cmz02)))
                , LTRIM(RTRIM(CONVERT(NVARCHAR(100), tc_cmz17)))
                , TRY_CONVERT(DECIMAL(28,6), tc_cmz03)
                , TRY_CONVERT(DECIMAL(28,6), tc_cmz04)
                , TRY_CONVERT(DECIMAL(28,6), tc_cmz05)
                , TRY_CONVERT(DECIMAL(28,6), tc_cmz06)
                , TRY_CONVERT(DECIMAL(28,6), tc_cmz07)
                , TRY_CONVERT(DECIMAL(28,6), tc_cmz08)
                , TRY_CONVERT(DECIMAL(28,6), tc_cmz09)
                , TRY_CONVERT(DECIMAL(28,6), tc_cmz10)
                , TRY_CONVERT(DECIMAL(28,6), tc_cmz11)
                , TRY_CONVERT(DECIMAL(28,6), tc_cmz12)
                , TRY_CONVERT(DECIMAL(28,6), tc_cmz13)
                , TRY_CONVERT(DECIMAL(28,6), tc_cmz14)
                , TRY_CONVERT(DECIMAL(28,6), tc_cmz18)
                , TRY_CONVERT(DECIMAL(28,6), tc_cmz19)
                , TRY_CONVERT(DECIMAL(28,6), tc_cmz20)
                , TRY_CONVERT(DECIMAL(28,6), tc_cmz15)
                , TRY_CONVERT(DECIMAL(28,6), tc_cmz16)
            FROM ERP_Staging.dbo.m302_tc_cmz_file
            WHERE tc_cmz01 IS NOT NULL;

            INSERT INTO #Jce
            SELECT DISTINCT
                  N'M302'
                , CONVERT(NVARCHAR(50), jce02)
            FROM ERP_Staging.dbo.m302_jce_file
            WHERE jce02 IS NOT NULL;

            INSERT INTO #Grade
            (
                  SourceCode
                , ItemNo
                , ManufacturingLotNo
                , ClassCode
            )
            SELECT
                  N'M302'
                , CONVERT(NVARCHAR(100), ITEM_NO)
                , CONVERT(NVARCHAR(100), MANUFACTURING_LOT_NO)
                , NULLIF
                  (
                      LTRIM(RTRIM(CONVERT(NVARCHAR(100), CLASS_CODE))),
                      N''
                  )
            FROM OPENQUERY
            (
                [ORACLE_LINKED_SERVER],
                '
                    SELECT
                          inj01 AS item_no
                        , inj02 AS manufacturing_lot_no
                        , MAX(TRIM(inj04)) AS class_code
                    FROM M302_2023.inj_file
                    WHERE inj03 = ''S008''
                    GROUP BY
                          inj01
                        , inj02
                '
            )
            WHERE ITEM_NO IS NOT NULL
              AND MANUFACTURING_LOT_NO IS NOT NULL;
        END;


        /*========================================================
          7. 索引
        ========================================================*/
        CREATE NONCLUSTERED INDEX IX_Ima
        ON #Ima(SourceCode, ItemNo);

        CREATE NONCLUSTERED INDEX IX_Imgs
        ON #Imgs
        (
              SourceCode
            , ItemNo
            , WarehouseNo
            , LocationNo
            , LotNo
            , SerialNo
            , ManufacturingLotNo
        )
        INCLUDE(Imgs11);

        CREATE NONCLUSTERED INDEX IX_Grade
        ON #Grade(SourceCode, ItemNo, ManufacturingLotNo)
        INCLUDE(ClassCode);

        CREATE NONCLUSTERED INDEX IX_Cmc
        ON #Cmc
        (
              SourceCode
            , ItemNo
            , WarehouseNo
            , LocationNo
            , LotNo
            , CczYear
            , CczMonth
        )
        INCLUDE(AgeDate);

        CREATE NONCLUSTERED INDEX IX_Cmcc
        ON #Cmcc
        (
              SourceCode
            , ItemNo
            , WarehouseNo
            , LocationNo
            , LotNo
            , SerialNo
            , ManufacturingLotNo
            , Imgs11
            , CczYear
            , CczMonth
        )
        INCLUDE(AgeDate);

        /*========================================================
          8. 計算符合 Y 的 InventoryKey
        ========================================================*/
        DROP TABLE IF EXISTS #ZeroResult;

        CREATE TABLE #ZeroResult
        (
              InventoryKey VARBINARY(32) NOT NULL
            , SourceCode   NVARCHAR(20)  NOT NULL
            , RuleCode     NVARCHAR(30)  NOT NULL
        );

        ;WITH Candidate AS
        (
            SELECT
                  s.InventoryKey
                , src.SourceCode
                , s.imgs01
                , s.imgs02
                , s.imgs03
                , s.imgs04
                , s.imgs05
                , s.imgs06
                , s.imgs09
                , s.ta_ima01
                , ccz.CczYear
                , ccz.CczMonth
                , ccz.BaseDate
                , ima.ItemCategory
                , ima.Ima918
                , ima.Ima921
                , ima.Ima943
                , grade.ClassCode
                , irow.Imgs11
                , ISNULL(irow.HasImgsRow, 0) AS HasImgsRow
                , ISNULL(agd_mfg.IsColor, 0) AS ManufacturingLotIsColor
                , ISNULL(agd_serial.IsColor, 0) AS SerialIsColor
                , special.SpecialFlag
                , agecalc.AgeStartDate
                , CASE
                      WHEN agecalc.AgeStartDate IS NULL
                          THEN 0
                      ELSE DATEDIFF
                           (
                               DAY,
                               agecalc.AgeStartDate,
                               ccz.BaseDate
                           )
                  END AS AgeDays
                , z.D1From
                , z.D1To
                , z.R1
                , z.D2From
                , z.D2To
                , z.R2
                , z.D3From
                , z.D3To
                , z.R3
                , z.D4From
                , z.D4To
                , z.R4
                , z.D5From
                , z.D5To
                , z.R5
                , z.D6From
                , z.R6
                , ISNULL(jce_match.IsExcludedWarehouse, 0)
                  AS IsExcludedWarehouse
            FROM dbo.InventoryInquirySnapshot AS s

            CROSS APPLY
            (
                SELECT
                    UPPER(LTRIM(RTRIM(CONVERT(NVARCHAR(20), s.OperatingCenter))))
                    AS SourceCode
            ) AS src

            INNER JOIN #Ccz AS ccz
                ON ccz.SourceCode = src.SourceCode

            OUTER APPLY
            (
                SELECT TOP (1)
                      i.ItemCategory
                    , i.Ima918
                    , i.Ima921
                    , i.Ima943
                FROM #Ima AS i
                WHERE i.SourceCode = src.SourceCode
                  AND i.ItemNo =
                      CONVERT(NVARCHAR(100), s.imgs01)
                      COLLATE Latin1_General_100_BIN2
            ) AS ima

            OUTER APPLY
            (
                SELECT TOP (1)
                      i.Imgs11
                    , CAST(1 AS INT) AS HasImgsRow
                FROM #Imgs AS i
                WHERE i.SourceCode = src.SourceCode
                  AND i.ItemNo =
                      CONVERT(NVARCHAR(100), s.imgs01)
                      COLLATE Latin1_General_100_BIN2
                  AND i.WarehouseNo =
                      CONVERT(NVARCHAR(50), s.imgs02)
                      COLLATE Latin1_General_100_BIN2
                  AND i.LocationNo =
                      CONVERT(NVARCHAR(50), s.imgs03)
                      COLLATE Latin1_General_100_BIN2
                  AND i.LotNo =
                      ISNULL
                      (
                          NULLIF
                          (
                              RTRIM(CONVERT(NVARCHAR(100), s.imgs04)),
                              N''
                          ),
                          N' '
                      )
                      COLLATE Latin1_General_100_BIN2
                  AND i.SerialNo =
                      ISNULL
                      (
                          NULLIF
                          (
                              RTRIM(CONVERT(NVARCHAR(100), s.imgs05)),
                              N''
                          ),
                          N' '
                      )
                      COLLATE Latin1_General_100_BIN2
                  AND i.ManufacturingLotNo =
                      ISNULL
                      (
                          NULLIF
                          (
                              RTRIM(CONVERT(NVARCHAR(100), s.imgs06)),
                              N''
                          ),
                          N' '
                      )
                      COLLATE Latin1_General_100_BIN2
            ) AS irow

            OUTER APPLY
            (
                SELECT TOP (1)
                    g.ClassCode
                FROM #Grade AS g
                WHERE g.SourceCode = src.SourceCode
                  AND g.ItemNo =
                      CONVERT(NVARCHAR(100), s.imgs01)
                      COLLATE Latin1_General_100_BIN2
                  AND g.ManufacturingLotNo =
                      CONVERT(NVARCHAR(100), s.imgs06)
                      COLLATE Latin1_General_100_BIN2
            ) AS grade

            OUTER APPLY
            (
                SELECT TOP (1)
                    CAST(1 AS INT) AS IsColor
                FROM #Agd AS a
                WHERE a.SourceCode = src.SourceCode
                  AND a.ColorNo =
                      CONVERT(NVARCHAR(100), s.imgs06)
                      COLLATE Latin1_General_100_BIN2
            ) AS agd_mfg

            OUTER APPLY
            (
                SELECT TOP (1)
                    CAST(1 AS INT) AS IsColor
                FROM #Agd AS a
                WHERE a.SourceCode = src.SourceCode
                  AND a.ColorNo =
                      CONVERT(NVARCHAR(100), s.imgs05)
                      COLLATE Latin1_General_100_BIN2
            ) AS agd_serial

            OUTER APPLY
            (
                SELECT TOP (1)
                    CAST(1 AS INT) AS HasOrder
                FROM #Oea AS o
                WHERE o.SourceCode = src.SourceCode
                  AND o.OrderNo =
                      CONVERT(NVARCHAR(100), s.imgs04)
                      COLLATE Latin1_General_100_BIN2
            ) AS oea_match

            OUTER APPLY
            (
                SELECT
                    CASE
                        WHEN LTRIM
                             (
                                 RTRIM
                                 (
                                     CONVERT
                                     (
                                         NVARCHAR(50),
                                         s.ta_ima01
                                     )
                                 )
                             ) IN (N'1', N'D')
                        THEN
                            CASE
                                WHEN ISNULL(oea_match.HasOrder, 0) = 1
                                THEN
                                    CASE
                                        WHEN CONVERT(NVARCHAR(100), s.imgs04)
                                             LIKE N'A1112%'
                                          OR CONVERT(NVARCHAR(100), s.imgs04)
                                             LIKE N'A1113%'
                                          OR CONVERT(NVARCHAR(100), s.imgs04)
                                             LIKE N'A3132%'
                                          OR CONVERT(NVARCHAR(100), s.imgs04)
                                             LIKE N'A1103%'
                                          OR CONVERT(NVARCHAR(100), s.imgs04)
                                             LIKE N'F1112%'
                                          OR CONVERT(NVARCHAR(100), s.imgs04)
                                             LIKE N'F1113%'
                                          OR CONVERT(NVARCHAR(100), s.imgs04)
                                             LIKE N'F3132%'
                                          OR CONVERT(NVARCHAR(100), s.imgs04)
                                             LIKE N'F1103%'
                                            THEN N'Y'
                                        ELSE N'N'
                                    END
                                WHEN CHARINDEX
                                     (
                                         N'T',
                                         ISNULL
                                         (
                                             CONVERT
                                             (
                                                 NVARCHAR(100),
                                                 s.imgs04
                                             ),
                                             N''
                                         )
                                     ) > 0
                                    THEN N'Y'
                                ELSE N'N'
                            END
                        ELSE N'N'
                    END AS SpecialFlag
            ) AS special

            OUTER APPLY
            (
                SELECT
                    MIN(c.AgeDate) AS AgeDate
                FROM #Cmc AS c
                WHERE c.SourceCode = src.SourceCode
                  AND c.ItemNo =
                      CONVERT(NVARCHAR(100), s.imgs01)
                      COLLATE Latin1_General_100_BIN2
                  AND c.WarehouseNo =
                      CONVERT(NVARCHAR(50), s.imgs02)
                      COLLATE Latin1_General_100_BIN2
                  AND c.LocationNo =
                      CONVERT(NVARCHAR(50), s.imgs03)
                      COLLATE Latin1_General_100_BIN2
                  AND c.LotNo =
                      ISNULL
                      (
                          NULLIF
                          (
                              RTRIM(CONVERT(NVARCHAR(100), s.imgs04)),
                              N''
                          ),
                          N' '
                      )
                      COLLATE Latin1_General_100_BIN2
                  AND c.CczYear = ccz.CczYear
                  AND c.CczMonth = ccz.CczMonth
                  AND ima.Ima918 = N'N'
                  AND ima.Ima921 = N'N'
            ) AS cmcdate

            OUTER APPLY
            (
                SELECT
                    MIN(c.AgeDate) AS AgeDate
                FROM #Cmcc AS c
                WHERE c.SourceCode = src.SourceCode
                  AND c.ItemNo =
                      CONVERT(NVARCHAR(100), s.imgs01)
                      COLLATE Latin1_General_100_BIN2
                  AND c.WarehouseNo =
                      CONVERT(NVARCHAR(50), s.imgs02)
                      COLLATE Latin1_General_100_BIN2
                  AND c.LocationNo =
                      CONVERT(NVARCHAR(50), s.imgs03)
                      COLLATE Latin1_General_100_BIN2
                  AND c.LotNo =
                      ISNULL
                      (
                          NULLIF
                          (
                              RTRIM(CONVERT(NVARCHAR(100), s.imgs04)),
                              N''
                          ),
                          N' '
                      )
                      COLLATE Latin1_General_100_BIN2
                  AND c.SerialNo =
                      ISNULL
                      (
                          NULLIF
                          (
                              RTRIM(CONVERT(NVARCHAR(100), s.imgs05)),
                              N''
                          ),
                          N' '
                      )
                      COLLATE Latin1_General_100_BIN2
                  AND c.ManufacturingLotNo =
                      ISNULL
                      (
                          NULLIF
                          (
                              RTRIM(CONVERT(NVARCHAR(100), s.imgs06)),
                              N''
                          ),
                          N' '
                      )
                      COLLATE Latin1_General_100_BIN2
                  AND c.Imgs11 =
                      CASE
                          WHEN src.SourceCode IN (N'SNX', N'M302')
                              THEN N' '
                          ELSE ISNULL
                               (
                                   NULLIF
                                   (
                                       RTRIM
                                       (
                                           CONVERT
                                           (
                                               NVARCHAR(100),
                                               irow.Imgs11
                                           )
                                       ),
                                       N''
                                   ),
                                   N' '
                               )
                      END
                      COLLATE Latin1_General_100_BIN2
                  AND c.CczYear = ccz.CczYear
                  AND c.CczMonth = ccz.CczMonth
                  AND
                      (
                          ima.Ima921 = N'Y'
                          OR ima.Ima918 = N'Y'
                      )
                  AND ima.Ima943 IN (N'1', N'2', N'3', N'4')
                  AND
                      (
                           (
                               ima.Ima943 = N'1'
                               AND ISNULL(agd_mfg.IsColor, 0) = 1
                           )
                        OR (
                               ima.Ima943 = N'2'
                               AND ISNULL(agd_serial.IsColor, 0) = 1
                           )
                        OR (
                               ima.Ima943 = N'3'
                               AND
                               (
                                   ISNULL(agd_mfg.IsColor, 0) = 1
                                   OR ISNULL(agd_serial.IsColor, 0) = 1
                               )
                           )
                        OR (
                               ima.Ima943 = N'4'
                               AND ISNULL(irow.HasImgsRow, 0) = 0
                           )
                      )
            ) AS cmccdate

            OUTER APPLY
            (
                SELECT
                    CASE
                        WHEN ima.Ima918 = N'N'
                         AND ima.Ima921 = N'N'
                            THEN cmcdate.AgeDate

                        WHEN ima.Ima921 = N'Y'
                          OR ima.Ima918 = N'Y'
                        THEN
                            CASE
                                WHEN ima.Ima943 = N'1'
                                 AND ISNULL(agd_mfg.IsColor, 0) = 1
                                    THEN cmccdate.AgeDate

                                WHEN ima.Ima943 = N'2'
                                 AND ISNULL(agd_serial.IsColor, 0) = 1
                                    THEN cmccdate.AgeDate

                                WHEN ima.Ima943 = N'3'
                                 AND
                                     (
                                         ISNULL(agd_mfg.IsColor, 0) = 1
                                         OR ISNULL(agd_serial.IsColor, 0) = 1
                                     )
                                    THEN cmccdate.AgeDate

                                WHEN ima.Ima943 = N'4'
                                 AND ISNULL(irow.HasImgsRow, 0) = 0
                                    THEN cmccdate.AgeDate

                                WHEN ima.Ima943 IN (N'0', N'4', N'N')
                                    THEN TRY_CONVERT(DATE, s.imgs09)

                                WHEN ima.Ima943 = N'1'
                                 AND ISNULL(agd_mfg.IsColor, 0) = 0
                                    THEN TRY_CONVERT(DATE, s.imgs09)

                                WHEN ima.Ima943 = N'2'
                                 AND ISNULL(agd_serial.IsColor, 0) = 0
                                    THEN TRY_CONVERT(DATE, s.imgs09)

                                WHEN ima.Ima943 = N'3'
                                 AND ISNULL(agd_mfg.IsColor, 0) = 0
                                 AND ISNULL(agd_serial.IsColor, 0) = 0
                                    THEN TRY_CONVERT(DATE, s.imgs09)

                                ELSE NULL
                            END
                        ELSE NULL
                    END AS AgeStartDate
            ) AS agecalc

            OUTER APPLY
            (
                SELECT TOP (1)
                      m.D1From
                    , m.D1To
                    , m.R1
                    , m.D2From
                    , m.D2To
                    , m.R2
                    , m.D3From
                    , m.D3To
                    , m.R3
                    , m.D4From
                    , m.D4To
                    , m.R4
                    , m.D5From
                    , m.D5To
                    , m.R5
                    , m.D6From
                    , m.R6
                FROM #Cmz AS m
                WHERE m.SourceCode = src.SourceCode
                  AND m.ItemTypeCode =
                      LTRIM
                      (
                          RTRIM
                          (
                              CONVERT
                              (
                                  NVARCHAR(50),
                                  s.ta_ima01
                              )
                          )
                      )
                      COLLATE Latin1_General_100_BIN2
                  AND m.SpecialFlag =
                      special.SpecialFlag
                      COLLATE Latin1_General_100_BIN2
                  AND
                      (
                          m.ItemCategory =
                          LTRIM
                          (
                              RTRIM
                              (
                                  CONVERT
                                  (
                                      NVARCHAR(100),
                                      ima.ItemCategory
                                  )
                              )
                          )
                          COLLATE Latin1_General_100_BIN2
                          OR m.ItemCategory = N'ALL'
                      )
                ORDER BY
                    CASE
                        WHEN m.ItemCategory =
                             LTRIM
                             (
                                 RTRIM
                                 (
                                     CONVERT
                                     (
                                         NVARCHAR(100),
                                         ima.ItemCategory
                                     )
                                 )
                             )
                             COLLATE Latin1_General_100_BIN2
                            THEN 0
                        ELSE 1
                    END
            ) AS z

            OUTER APPLY
            (
                SELECT TOP (1)
                    CAST(1 AS INT) AS IsExcludedWarehouse
                FROM #Jce AS j
                WHERE j.SourceCode = src.SourceCode
                  AND j.WarehouseNo =
                      CONVERT(NVARCHAR(50), s.imgs02)
                      COLLATE Latin1_General_100_BIN2
            ) AS jce_match

            WHERE
                  (
                      src.SourceCode = N'SNX'
                      AND @IncludeSNX = 1
                  )
               OR (
                      src.SourceCode = N'GFUN'
                      AND @IncludeGFUN = 1
                  )
               OR (
                      src.SourceCode = N'M302'
                      AND @IncludeM302 = 1
                  )
        ),
        Qualified AS
        (
            SELECT
                  InventoryKey
                , SourceCode
                , CASE
                      WHEN UPPER
                           (
                               LTRIM
                               (
                                   RTRIM
                                   (
                                       ISNULL(ClassCode, N'')
                                   )
                               )
                           ) = N'C'
                          THEN N'CLASS_C'

                      WHEN UPPER
                           (
                               LTRIM
                               (
                                   RTRIM
                                   (
                                       ISNULL(ClassCode, N'')
                                   )
                               )
                           ) = N'B'
                       AND AgeDays >= 366
                          THEN N'CLASS_B_366'

                      WHEN ISNULL(R1, 0) >= 100
                       AND AgeDays >= D1From
                       AND AgeDays <= D1To
                          THEN N'RANGE_1'

                      WHEN ISNULL(R2, 0) >= 100
                       AND AgeDays >= D2From
                       AND AgeDays <= D2To
                          THEN N'RANGE_2'

                      WHEN ISNULL(R3, 0) >= 100
                       AND AgeDays >= D3From
                       AND AgeDays <= D3To
                          THEN N'RANGE_3'

                      WHEN ISNULL(R4, 0) >= 100
                       AND AgeDays >= D4From
                       AND AgeDays <= D4To
                          THEN N'RANGE_4'

                      WHEN ISNULL(R5, 0) >= 100
                       AND AgeDays >= D5From
                       AND AgeDays <= D5To
                          THEN N'RANGE_5'

                      WHEN ISNULL(R6, 0) >= 100
                       AND AgeDays >= D6From
                          THEN N'RANGE_6'
                  END AS RuleCode
            FROM Candidate
            WHERE IsExcludedWarehouse = 0
        )
        INSERT INTO #ZeroResult
        (
              InventoryKey
            , SourceCode
            , RuleCode
        )
        SELECT
              InventoryKey
            , SourceCode
            , RuleCode
        FROM Qualified
        WHERE RuleCode IS NOT NULL;

        ;WITH Ranked AS
        (
            SELECT
                  InventoryKey
                , SourceCode
                , RuleCode
                , ROW_NUMBER() OVER
                  (
                      PARTITION BY SourceCode, InventoryKey
                      ORDER BY
                          CASE RuleCode
                              WHEN N'CLASS_C'     THEN 1
                              WHEN N'CLASS_B_366' THEN 2
                              ELSE 3
                          END,
                          RuleCode
                  ) AS rn
            FROM #ZeroResult
        )
        DELETE FROM Ranked
        WHERE rn > 1;

        CREATE UNIQUE CLUSTERED INDEX CIX_ZeroResult
        ON #ZeroResult(SourceCode, InventoryKey);

        /*========================================================
          9. 回寫 Snapshot
        ========================================================*/
        BEGIN TRANSACTION;

        UPDATE s
        SET s.[zero] = N'N'
        FROM dbo.InventoryInquirySnapshot AS s
        WHERE
              (
                  @IncludeSNX = 1
                  AND s.OperatingCenter = N'SNX'
              )
           OR (
                  @IncludeGFUN = 1
                  AND s.OperatingCenter = N'GFUN'
              )
           OR (
                  @IncludeM302 = 1
                  AND s.OperatingCenter = N'M302'
              );

        SET @ResetRows = @@ROWCOUNT;

        UPDATE s
        SET s.[zero] = N'Y'
        FROM dbo.InventoryInquirySnapshot AS s
        INNER JOIN #ZeroResult AS z
            ON z.InventoryKey = s.InventoryKey
           AND z.SourceCode = s.OperatingCenter;

        SET @MarkedRows = @@ROWCOUNT;

        COMMIT TRANSACTION;

        SET @CompletedAt = SYSDATETIME();

        /*========================================================
          10. 結果
        ========================================================*/
        SELECT
              c.SourceCode
            , c.CczYear
            , c.CczMonth
            , c.BaseDate AS CalculationBaseDate
            , COUNT_BIG(s.InventoryKey) AS SnapshotRows
            , SUM
              (
                  CASE
                      WHEN s.[zero] = N'Y' THEN 1
                      ELSE 0
                  END
              ) AS ZeroYRows
            , SUM
              (
                  CASE
                      WHEN ISNULL(s.[zero], N'N') <> N'Y' THEN 1
                      ELSE 0
                  END
              ) AS ZeroNRows
        FROM #Ccz AS c
        LEFT JOIN dbo.InventoryInquirySnapshot AS s
            ON s.OperatingCenter = c.SourceCode
        GROUP BY
              c.SourceCode
            , c.CczYear
            , c.CczMonth
            , c.BaseDate
        ORDER BY c.SourceCode;

        SELECT
              SourceCode
            , RuleCode
            , COUNT_BIG(*) AS Rows
        FROM #ZeroResult
        GROUP BY
              SourceCode
            , RuleCode
        ORDER BY
              SourceCode
            , RuleCode;

        SELECT
              @ResetRows AS ResetRows
            , @MarkedRows AS MarkedYRows
            , @StartedAt AS StartedAt
            , @CompletedAt AS CompletedAt
            , DATEDIFF(SECOND, @StartedAt, @CompletedAt)
              AS ElapsedSeconds;

        EXEC sys.sp_releaseapplock
              @Resource = N'SAL_MRT.InventoryInquiry.ZeroFlag'
            , @LockOwner = N'Session';
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0
            ROLLBACK TRANSACTION;

        EXEC sys.sp_releaseapplock
              @Resource = N'SAL_MRT.InventoryInquiry.ZeroFlag'
            , @LockOwner = N'Session';

        THROW;
    END CATCH;
END;


GO
