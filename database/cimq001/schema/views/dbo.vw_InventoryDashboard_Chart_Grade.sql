USE [SAL_MRT];
GO



/*==============================================================
  4. 等級分布
==============================================================*/
CREATE   VIEW dbo.vw_InventoryDashboard_Chart_Grade
AS
SELECT
      CASE
          WHEN ISNULL([等級標準化], N'') = N'A' THEN 1
          WHEN ISNULL([等級標準化], N'') = N'B' THEN 2
          WHEN ISNULL([等級標準化], N'') = N'C' THEN 3
          WHEN ISNULL([等級標準化], N'') = N''  THEN 99
          ELSE 90
      END AS [顯示順序]

    , CASE
          WHEN ISNULL([等級標準化], N'') = N''
          THEN N'未指定'
          ELSE [等級標準化]
      END AS [等級]

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
      [等級標準化];

GO
