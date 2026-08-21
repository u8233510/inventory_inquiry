USE [SAL_MRT];
GO



/*==============================================================
  1. 品類庫存金額
==============================================================*/
CREATE   VIEW dbo.vw_InventoryDashboard_Chart_Category
AS
SELECT
      CASE [品類]
          WHEN N'布'       THEN 1
          WHEN N'胚布'     THEN 2
          WHEN N'紗'       THEN 3
          WHEN N'盤頭紗'   THEN 4
          WHEN N'成衣'     THEN 5
          WHEN N'領片'     THEN 6
          WHEN N'軍工'     THEN 7
          ELSE 99
      END AS [顯示順序]

    , ISNULL(NULLIF(LTRIM(RTRIM([品類])), N''), N'未分類') AS [品類]

    , COUNT_BIG(*) AS [資料筆數]

    , COUNT(DISTINCT [料號]) AS [料號數]

    , CAST
      (
          SUM(ISNULL([庫存金額], 0))
          AS DECIMAL(38, 2)
      ) AS [庫存金額]

    , CAST
      (
          SUM
          (
              CASE
                  WHEN [等級標準化] = N'B'
                  THEN ISNULL([庫存金額], 0)
                  ELSE 0
              END
          )
          AS DECIMAL(38, 2)
      ) AS [B級庫存金額]

    , CAST
      (
          SUM
          (
              CASE
                  WHEN [等級標準化] = N'C'
                  THEN ISNULL([庫存金額], 0)
                  ELSE 0
              END
          )
          AS DECIMAL(38, 2)
      ) AS [C級庫存金額]

    , CAST
      (
          SUM
          (
              CASE
                  WHEN UPPER(LTRIM(RTRIM(ISNULL([訂單結案], N'')))) = N'Y'
                  THEN ISNULL([庫存金額], 0)
                  ELSE 0
              END
          )
          AS DECIMAL(38, 2)
      ) AS [訂單結案庫存金額]

    , CAST
      (
          SUM
          (
              CASE
                  WHEN [庫齡天數] > 180
                  THEN ISNULL([庫存金額], 0)
                  ELSE 0
              END
          )
          AS DECIMAL(38, 2)
      ) AS [久置180天庫存金額]

    , SUM
      (
          CASE
              WHEN ISNULL([數量], 0) <> 0
               AND ISNULL([平均成本], 0) = 0
              THEN 1
              ELSE 0
          END
      ) AS [成本為零筆數]

    , SUM
      (
          CASE
              WHEN ISNULL([平均成本], 0) < 0
              THEN 1
              ELSE 0
          END
      ) AS [負平均成本筆數]

    , CAST
      (
          SUM
          (
              CASE
                  WHEN ISNULL([平均成本], 0) < 0
                  THEN ISNULL([庫存金額], 0)
                  ELSE 0
              END
          )
          AS DECIMAL(38, 2)
      ) AS [負成本影響金額]

FROM dbo.vw_InventoryDashboard_Base
GROUP BY
      [品類];

GO
