USE [SAL_MRT];
GO

/*
===============================================================================
庫存分析 UI 專用 Base VIEW
===============================================================================

問題：
dbo.vw_InventoryDashboard_Base 沒有 [302專案否]，
但 dbo.vw_InventoryInquiry_Base 有 [零元專案否]。

處理：
依 [庫存識別碼] 關聯，只補入一個欄位：

[零元專案否] → [302專案否]

不修改原本的 dbo.vw_InventoryDashboard_Base。
===============================================================================
*/

CREATE OR ALTER VIEW dbo.vw_InventoryDashboard_Base_UI
AS
SELECT
      d.*
    , i.[零元專案否] AS [302專案否]
FROM dbo.vw_InventoryDashboard_Base AS d
LEFT JOIN dbo.vw_InventoryInquiry_Base AS i
    ON i.[庫存識別碼] = d.[庫存識別碼];
GO

SELECT TOP (20)
      [庫存識別碼]
    , [302專案否]
    , [品類]
    , [胚布類型名稱]
    , [入庫日期]
    , [庫齡區間]
    , [庫存金額]
FROM dbo.vw_InventoryDashboard_Base_UI;
GO
