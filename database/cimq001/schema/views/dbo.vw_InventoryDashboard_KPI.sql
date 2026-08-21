USE [SAL_MRT];
GO


CREATE   VIEW dbo.vw_InventoryDashboard_KPI
AS
SELECT
      COUNT_BIG(*) AS [資料總筆數]

    , SUM
      (
          CASE
              WHEN ISNULL([數量], 0) <> 0 THEN 1
              ELSE 0
          END
      ) AS [有庫存筆數]

    , COUNT
      (
          DISTINCT
          CASE
              WHEN ISNULL([數量], 0) <> 0 THEN [料號]
              ELSE NULL
          END
      ) AS [庫存料號數]

    , CAST
      (
          SUM(ISNULL([庫存金額], 0))
          AS DECIMAL(38, 2)
      ) AS [總庫存金額]

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

    , COUNT
      (
          DISTINCT
          CASE
              WHEN UPPER(LTRIM(RTRIM(ISNULL([訂單結案], N'')))) = N'Y'
              THEN [料號]
              ELSE NULL
          END
      ) AS [訂單結案料號數]

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

    , COUNT
      (
          DISTINCT
          CASE
              WHEN [庫齡天數] > 180
              THEN [料號]
              ELSE NULL
          END
      ) AS [久置180天料號數]

    , SUM
      (
          CASE
              WHEN ISNULL([數量], 0) < 0 THEN 1
              ELSE 0
          END
      ) AS [負庫存筆數]

    , CAST
      (
          SUM
          (
              CASE
                  WHEN ISNULL([數量], 0) < 0
                  THEN ISNULL([庫存金額], 0)
                  ELSE 0
              END
          )
          AS DECIMAL(38, 2)
      ) AS [負庫存金額]

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
              WHEN ISNULL([平均成本], 0) < 0 THEN 1
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

    , MIN([入庫日期]) AS [最早入庫日期]
    , MAX([入庫日期]) AS [最近入庫日期]
    , MAX([異動日期]) AS [最近異動日期]

FROM dbo.vw_InventoryDashboard_Base;

GO
