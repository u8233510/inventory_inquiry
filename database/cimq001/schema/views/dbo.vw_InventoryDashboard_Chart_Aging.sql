USE [SAL_MRT];
GO



/*==============================================================
  3. 庫齡分布
==============================================================*/
CREATE   VIEW dbo.vw_InventoryDashboard_Chart_Aging
AS
SELECT
      CASE
          WHEN [庫齡區間] = N'0～30天'       THEN 1
          WHEN [庫齡區間] = N'31～90天'      THEN 2
          WHEN [庫齡區間] = N'91～180天'     THEN 3
          WHEN [庫齡區間] = N'181～365天'    THEN 4
          WHEN [庫齡區間] = N'365天以上'     THEN 5
          WHEN [庫齡區間] = N'未提供'        THEN 98
          WHEN [庫齡區間] = N'日期異常'      THEN 99
          ELSE 100
      END AS [顯示順序]

    , ISNULL([庫齡區間], N'未提供') AS [庫齡區間]

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
      [庫齡區間];

GO
