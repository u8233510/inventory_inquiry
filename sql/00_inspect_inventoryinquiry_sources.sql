USE [SAL_MRT];
GO

/*
===============================================================================
InventoryInquiry 資料來源檢查（v13.4）
- 分析頁籤固定使用 dbo.vw_InventoryInquiry_Base
- 不做資料來源自動選擇或備援切換
- 庫存明細仍使用各 dbo.vw_InventoryInquiry_Type* View
- 302專案規則：批號第2碼起連續4碼為 1132 或 3132
- 彈性否直接使用 dbo.vw_InventoryInquiry_Base.[彈性否]
===============================================================================
*/

DECLARE @Objects TABLE
(
    SchemaName sysname,
    ObjectName sysname,
    Purpose nvarchar(200)
);

INSERT INTO @Objects (SchemaName, ObjectName, Purpose)
VALUES
    (N'dbo', N'InventoryInquiryActivity',    N'庫存異動資料'),
    (N'dbo', N'InventoryInquirySnapshot',    N'底層庫存快照'),
    (N'dbo', N'vw_InventoryInquiry',         N'完整庫存查詢 View'),
    (N'dbo', N'vw_InventoryInquiry_Base',    N'分析固定來源'),
    (N'dbo', N'vw_InventoryInquiry_Type189', N'類型1／8／9明細'),
    (N'dbo', N'vw_InventoryInquiry_Type2',   N'類型2明細'),
    (N'dbo', N'vw_InventoryInquiry_Type3',   N'類型3明細'),
    (N'dbo', N'vw_InventoryInquiry_Type4',   N'類型4明細'),
    (N'dbo', N'vw_InventoryInquiry_TypeF',   N'類型F明細');

SELECT
    x.Purpose AS [用途],
    x.SchemaName + N'.' + x.ObjectName AS [物件名稱],
    CASE o.type WHEN N'U' THEN N'TABLE' WHEN N'V' THEN N'VIEW' ELSE N'不存在' END AS [物件類型],
    CASE WHEN o.object_id IS NULL THEN N'不存在' ELSE N'存在' END AS [狀態],
    COUNT(c.column_id) AS [欄位數]
FROM @Objects AS x
LEFT JOIN sys.schemas AS s
    ON s.name = x.SchemaName
LEFT JOIN sys.objects AS o
    ON o.schema_id = s.schema_id
   AND o.name = x.ObjectName
   AND o.type IN (N'U', N'V')
LEFT JOIN sys.columns AS c
    ON c.object_id = o.object_id
GROUP BY x.Purpose, x.SchemaName, x.ObjectName, o.type, o.object_id
ORDER BY x.ObjectName;
GO

SELECT
    s.name + N'.' + o.name AS [物件名稱],
    c.column_id AS [欄位順序],
    c.name AS [欄位名稱],
    t.name AS [資料型別],
    c.max_length AS [長度],
    c.precision AS [精度],
    c.scale AS [小數位]
FROM sys.objects AS o
INNER JOIN sys.schemas AS s ON s.schema_id = o.schema_id
INNER JOIN sys.columns AS c ON c.object_id = o.object_id
INNER JOIN sys.types AS t ON t.user_type_id = c.user_type_id
WHERE o.type IN (N'U', N'V')
  AND
  (
      o.name LIKE N'InventoryInquiry%'
      OR o.name LIKE N'vw_InventoryInquiry%'
  )
ORDER BY s.name, o.name, c.column_id;
GO

DECLARE @SourceObjectId int = OBJECT_ID(N'dbo.vw_InventoryInquiry_Base');

SELECT
    N'dbo.vw_InventoryInquiry_Base' AS [分析固定來源],
    R.AnalysisField AS [分析用途],
    R.CandidateColumns AS [可接受欄位],
    CASE
        WHEN @SourceObjectId IS NULL THEN N'分析固定來源不存在'
        WHEN EXISTS
        (
            SELECT 1
            FROM sys.columns AS c
            WHERE c.object_id = @SourceObjectId
              AND CHARINDEX(N'|' + c.name + N'|', N'|' + R.CandidateColumns + N'|') > 0
        ) THEN N'存在'
        ELSE N'缺少'
    END AS [檢查結果]
FROM
(
    VALUES
        (N'快照日期', N'計算基準日|快照時間'),
        (N'入庫日期', N'入庫日期'),
        (N'302專案判斷批號', N'批號(訂單/請購單)'),
        (N'類型分類', N'類型'),
        (N'布種別', N'胚布類型'),
        (N'彈性否', N'彈性否'),
        (N'料件編號', N'料號'),
        (N'庫存數量', N'數量'),
        (N'庫存單位', N'單位'),
        (N'平均成本', N'平均成本'),
        (N'帳面價值', N'帳面價值'),
        (N'提列率', N'提列率|呆滯比率|備抵率|跌價率'),
        (N'品牌商', N'Final Buyer名稱|廠牌名稱|廠牌'),
        (N'歸屬部門', N'庫存歸屬部門說明|庫存歸屬部門|業務部門簡稱|業務部門'),
        (N'已收胚款排除', N'已收胚款否|收胚款否|胚款已收否')
) AS R(AnalysisField, CandidateColumns)
ORDER BY R.AnalysisField;
GO

SELECT
    CASE
        WHEN SUBSTRING(ISNULL([批號(訂單/請購單)], N''), 2, 4)
             IN (N'1132', N'3132')
        THEN N'Y'
        ELSE N'N'
    END AS [302專案否],
    COUNT_BIG(*) AS [筆數],
    CAST(SUM(ISNULL([數量], 0) * ISNULL([平均成本], 0)) AS decimal(38,2)) AS [存貨金額]
FROM dbo.vw_InventoryInquiry_Base
GROUP BY
    CASE
        WHEN SUBSTRING(ISNULL([批號(訂單/請購單)], N''), 2, 4)
             IN (N'1132', N'3132')
        THEN N'Y'
        ELSE N'N'
    END
ORDER BY [302專案否] DESC;
GO


/*=============================================================================
彈性否實際值檢查：View 應直接提供「彈性／非彈性」
=============================================================================*/
SELECT
    [彈性否],
    COUNT_BIG(*) AS [筆數],
    CAST(SUM(ISNULL([數量], 0) * ISNULL([平均成本], 0)) AS decimal(38,2)) AS [存貨金額]
FROM dbo.vw_InventoryInquiry_Base
GROUP BY [彈性否]
ORDER BY
    CASE [彈性否]
        WHEN N'彈性' THEN 1
        WHEN N'非彈性' THEN 2
        ELSE 9
    END,
    [彈性否];
GO
