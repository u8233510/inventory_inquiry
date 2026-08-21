USE [SAL_MRT];
GO



/*==============================================================
  2. 倉庫庫存金額
==============================================================*/
CREATE   VIEW dbo.vw_InventoryDashboard_Chart_Warehouse
AS
SELECT
      ISNULL(NULLIF(LTRIM(RTRIM([倉庫])), N''), N'未指定') AS [倉庫]

    , ISNULL
      (
          NULLIF(LTRIM(RTRIM([倉庫名稱])), N''),
          N'未指定'
      ) AS [倉庫名稱]

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
      ISNULL(NULLIF(LTRIM(RTRIM([倉庫])), N''), N'未指定')
    , ISNULL
      (
          NULLIF(LTRIM(RTRIM([倉庫名稱])), N''),
          N'未指定'
      );

GO
