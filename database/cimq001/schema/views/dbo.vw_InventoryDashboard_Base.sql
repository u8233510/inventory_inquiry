USE [SAL_MRT];
GO


CREATE   VIEW dbo.vw_InventoryDashboard_Base
AS
WITH InventoryBase AS
(
    SELECT
          CAST
          (
              CASE
                  WHEN [類型] IN (N'1', N'8', N'9') THEN N'Type189'
                  WHEN [類型] = N'2' THEN N'Type2'
                  WHEN [類型] = N'3' THEN N'Type3'
                  WHEN [類型] = N'4' THEN N'Type4'
                  ELSE N'TypeF'
              END
              AS NVARCHAR(20)
          ) AS [來源View]

        , [類型]

        , CAST
          (
              CASE [類型]
                  WHEN N'1' THEN N'布'
                  WHEN N'2' THEN N'胚布'
                  WHEN N'3' THEN N'紗'
                  WHEN N'4' THEN N'盤頭紗'
                  WHEN N'8' THEN N'成衣'
                  WHEN N'9' THEN N'領片'
                  WHEN N'F' THEN N'軍工'
                  ELSE N'其他'
              END
              AS NVARCHAR(20)
          ) AS [品類]

        , [胚布類型]

        , CAST
          (
              CASE
                  WHEN [類型] <> N'2' THEN NULL
                  WHEN [胚布類型] = N'1' THEN N'針織'
                  WHEN [胚布類型] = N'2' THEN N'平織'
                  WHEN [胚布類型] = N'3' THEN N'領片胚布'
                  WHEN [胚布類型] = N'4' THEN N'不織布'
                  ELSE N'其他'
              END
              AS NVARCHAR(50)
          ) AS [胚布類型名稱]

        , [料號]
        , [品名]
        , ISNULL([數量], 0) AS [數量]
        , [單位]
        , [倉庫]
        , [倉庫名稱]
        , [業務姓名]
        , [庫存歸屬部門]
        , [庫存歸屬部門說明]
        , [入庫日期]
        , [異動日期]
        , [等級]

        , NULLIF
          (
              UPPER(LTRIM(RTRIM([等級]))),
              N''
          ) AS [等級標準化]

        , CAST
          (
              CASE
                  WHEN [類型] = N'4' THEN NULL
                  ELSE [訂單結案]
              END
              AS NVARCHAR(100)
          ) AS [訂單結案]

        , ISNULL([平均成本], 0) AS [平均成本]

        , CAST
          (
              ISNULL([數量], 0)
              * ISNULL([平均成本], 0)
              AS DECIMAL(28, 2)
          ) AS [庫存金額]

        , CASE
              WHEN [入庫日期] IS NULL THEN NULL
              ELSE DATEDIFF
                   (
                       DAY,
                       [入庫日期],
                       CONVERT(DATE, GETDATE())
                   )
          END AS [庫齡天數]

    FROM dbo.vw_InventoryInquiry_Base
),
Normalized AS
(
    SELECT
          *
        , CAST
          (
              CASE
                  WHEN [庫齡天數] IS NULL THEN N'未提供'
                  WHEN [庫齡天數] < 0 THEN N'日期異常'
                  WHEN [庫齡天數] <= 30 THEN N'0～30天'
                  WHEN [庫齡天數] <= 90 THEN N'31～90天'
                  WHEN [庫齡天數] <= 180 THEN N'91～180天'
                  WHEN [庫齡天數] <= 365 THEN N'181～365天'
                  ELSE N'365天以上'
              END
              AS NVARCHAR(20)
          ) AS [庫齡區間]

    FROM InventoryBase
)
SELECT
      [來源View]
    , [類型]
    , [品類]
    , [胚布類型]
    , [胚布類型名稱]
    , [料號]
    , [品名]
    , [數量]
    , [單位]
    , [倉庫]
    , [倉庫名稱]
    , [業務姓名]
    , [庫存歸屬部門]
    , [庫存歸屬部門說明]
    , [入庫日期]
    , [異動日期]
    , [等級]
    , [等級標準化]
    , [訂單結案]
    , [平均成本]
    , [庫存金額]
    , [庫齡天數]
    , [庫齡區間]

    , CAST
      (
          CASE
              WHEN [等級標準化] = N'B' THEN 1
              ELSE 0
          END
          AS BIT
      ) AS [是否B級]

    , CAST
      (
          CASE
              WHEN [等級標準化] = N'C' THEN 1
              ELSE 0
          END
          AS BIT
      ) AS [是否C級]

    , CAST
      (
          CASE
              WHEN [庫齡天數] > 180 THEN 1
              ELSE 0
          END
          AS BIT
      ) AS [是否久置180天]

    , CAST
      (
          CASE
              WHEN [數量] <> 0 THEN 1
              ELSE 0
          END
          AS BIT
      ) AS [是否有庫存]

    , CAST
      (
          CASE
              WHEN [數量] < 0 THEN 1
              ELSE 0
          END
          AS BIT
      ) AS [是否負庫存]

FROM Normalized;

GO
