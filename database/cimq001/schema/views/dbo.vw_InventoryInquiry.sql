USE [SAL_MRT];
GO







/*
===============================================================================
建立 庫存查詢 VIEW
===============================================================================
VIEW 名稱：
    dbo.vw_InventoryInquiry

設計原則：
  1. 一筆 Snapshot 對應一筆資料，不因 Activity JOIN 造成重複。
  2. 已知意義的欄位全部使用中文名稱。
  3. 不依類型隱藏欄位，全部欄位都提供給查詢端。
  4. [異動日期] 為該 InventoryKey 最新一筆 TLFS 異動日期。
  5. [計算基準日] 為 Snapshot 建立日期。
  6. VIEW 無法接受 @BeginDate、@EndDate，因此日期區間由 查詢 SQL 的
     WHERE [異動日期] BETWEEN ... AND ... 負責。
===============================================================================
*/

CREATE   VIEW [dbo].[vw_InventoryInquiry]
AS
SELECT
      CONVERT(VARCHAR(64), s.InventoryKey, 2) AS [庫存識別碼]
    , s.LoadBatchId                           AS [載入批次ID]
    , s.SnapshotTime                          AS [快照時間]
    , CONVERT(DATE, s.SnapshotTime)           AS [計算基準日]
    , act.ActivityDate                        AS [異動日期]

    , s.tc_imv01                              AS [零元專案否]
    , s.ta_ima01                              AS [類型]
    , s.ta_ima20                              AS [胚布類型]

    , s.imgs01                                AS [料號]
    , s.ima02                                 AS [品名]
    , s.ta_ima158                             AS [Tranzend上架品名]
    , s.ima021                                AS [規格]
    ,  CASE
            WHEN LTRIM(RTRIM(s.ta_ima84)) = N'1' THEN N'彈性'
            WHEN LTRIM(RTRIM(s.ta_ima84)) = N'2' THEN N'非彈性'
            ELSE s.ta_ima84
       END AS [彈性否]

    , s.imgs02                                AS [倉庫]
    , s.imd02                                 AS [倉庫名稱]
    , s.imgs03                                AS [儲位]
    , s.ime03                                 AS [儲位名稱]

    , s.imgs04                                AS [批號(訂單/請購單)]
    , s.imgs06                                AS [製造批號(顏色)]
    , s.imgs06_desc                           AS [顏色說明]
    , s.imgs05                                AS [序號(尺寸)]
    , s.imgs05_desc                           AS [尺寸說明]

    , s.imgs09                                AS [入庫日期]
    , s.imgs08                                AS [數量]
    , s.imgs07                                AS [單位]

    , s.tc_bmz11                              AS [興采胚布批號]
    , s.tc_rvbs22                             AS [布疋號]
    , s.tc_rvbs23                             AS [含漿否]
    , s.tc_rvbs24                             AS [限定染色]
    , s.tc_rvbs24_desc                        AS [限定染色名稱]
    , s.tc_rvbs25                             AS [限定染色原因]
    , s.tc_rvbs25_desc                        AS [限定染色原因名稱]

    , s.pmm01                                 AS [採購單號]

    , s.ta_oea11                              AS [訂單類別代碼]
    , s.tc_oad03                              AS [訂單類別]
    , s.ta_oea01_b                            AS [Final Buyer ID]
    , s.occ02                                 AS [Final Buyer名稱]

    , s.ta_sfb05                              AS [中文色名]
    , s.ta_sfb04                              AS [英文色名]
    , s.ta_sfb06                              AS [興采色號]
    , s.ta_sfb38                              AS [外廠色號]

    , s.pmn06                                 AS [廠商料件編號]
    , s.pmc01                                 AS [廠商ID]
    , s.pmc03                                 AS [廠商簡稱]

    , s.ta_ima39                              AS [廠牌]
    , s.mse02                                 AS [廠牌名稱]
    , s.ta_ima91                              AS [織軸類別]

    , s.ta_oea05_b                            AS [訂單結案]
    , s.oeb70d                                AS [結案日期]

    , s.oea14                                 AS [業務]
    , s.oea14_desc                            AS [業務姓名]
    , s.oea15                                 AS [業務部門]
    , s.oea15_desc                            AS [業務部門簡稱]

    , s.ta_imgs01                             AS [理由碼]
    , s.ta_imgs01_d                           AS [理由碼說明]
    , s.ta_imgs02                             AS [庫存歸屬部門]
    , s.ta_imgs02_d                           AS [庫存歸屬部門說明]

    , s.sfu16                                 AS [生管/採購人員]
    , s.sfu16_desc                            AS [生管/採購人員姓名]

    , s.oeaud04                               AS [PI舊單號]
    , s.oeb15                                 AS [訂單客戶交期]
    , s.prepare                               AS [計畫性備產否]
    , s.ccc23                                 AS [平均成本]

    , s.att01_code                            AS [att01代碼]
    , s.att01_name                            AS [att01名稱]
    , s.att01                                 AS [att01值]

    , s.att02_code                            AS [att02代碼]
    , s.att02_name                            AS [att02名稱]
    , s.att02                                 AS [att02值]

    , s.att03_code                            AS [att03代碼]
    , s.att03_name                            AS [att03名稱]
    , s.att03                                 AS [att03值]

    , s.att04_code                            AS [att04代碼]
    , s.att04_name                            AS [att04名稱]
    , s.att04                                 AS [att04值]

    , s.att05_code                            AS [att05代碼]
    , s.att05_name                            AS [att05名稱]
    , s.att05                                 AS [att05值]

    , s.att06_code                            AS [att06代碼]
    , s.att06_name                            AS [att06名稱]
    , s.att06                                 AS [att06值]

    , s.att07_code                            AS [att07代碼]
    , s.att07_name                            AS [att07名稱]
    , s.att07                                 AS [att07值]

    , s.att08_code                            AS [att08代碼]
    , s.att08_name                            AS [att08名稱]
    , s.att08                                 AS [att08值]

    , s.att09_code                            AS [att09代碼]
    , s.att09_name                            AS [att09名稱]
    , s.att09                                 AS [att09值]

    , s.att10_code                            AS [att10代碼]
    , s.att10_name                            AS [att10名稱]
    , s.att10                                 AS [att10值]

    , s.source_order                          AS [來源單號]
    , s.source_item                           AS [來源項次]
    , s.sales_order_item                      AS [訂單項次]
    , s.grade                                 AS [等級]
    , s.receive_cloth_no                      AS [收布編號]
    , s.vendor_item_no                        AS [廠商料號]
    , s.inventory_memo                        AS [備註]

FROM dbo.InventoryInquirySnapshot_Work AS s

OUTER APPLY
(
    SELECT
        MAX(a.ActivityDate) AS ActivityDate
    FROM dbo.InventoryInquiryActivity AS a
    WHERE a.InventoryKey = s.InventoryKey
      AND a.ActivityType = N'TLFS'
) AS act;

GO
