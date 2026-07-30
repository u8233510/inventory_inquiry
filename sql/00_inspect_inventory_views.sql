USE [SAL_MRT];
GO

/*
用途：
1. 確認各庫存明細 VIEW 的全部欄位。
2. 將實際欄位名稱填入專案根目錄 field_map.json。
*/

DECLARE @Views TABLE
(
    SchemaName sysname,
    ViewName   sysname
);

INSERT INTO @Views (SchemaName, ViewName)
VALUES
    (N'dbo', N'vw_InventoryInquiry_Type189'),
    (N'dbo', N'vw_InventoryInquiry_Type2'),
    (N'dbo', N'vw_InventoryInquiry_Type3'),
    (N'dbo', N'vw_InventoryInquiry_Type4'),
    (N'dbo', N'vw_InventoryInquiry_TypeF');

SELECT
    s.name AS [SchemaName],
    v.name AS [ViewName],
    c.column_id AS [ColumnOrder],
    c.name AS [ColumnName],
    t.name AS [DataType],
    c.max_length AS [MaxLength],
    c.precision AS [Precision],
    c.scale AS [Scale],
    c.is_nullable AS [IsNullable]
FROM sys.views AS v
INNER JOIN sys.schemas AS s
    ON s.schema_id = v.schema_id
INNER JOIN sys.columns AS c
    ON c.object_id = v.object_id
INNER JOIN sys.types AS t
    ON t.user_type_id = c.user_type_id
INNER JOIN @Views AS x
    ON x.SchemaName = s.name
   AND x.ViewName = v.name
ORDER BY
    s.name,
    v.name,
    c.column_id;
GO

/*
類型 1、8、9 共用 vw_InventoryInquiry_Type189。
請特別確認 VIEW 內哪一欄是類型辨識欄位，
並將欄位名稱填入 field_map.json 的 type_discriminator。
*/
SELECT TOP (100) *
FROM dbo.vw_InventoryInquiry_Type189;
GO

SELECT TOP (100) *
FROM dbo.vw_InventoryInquiry_Type2;
GO

SELECT TOP (100) *
FROM dbo.vw_InventoryInquiry_Type3;
GO

SELECT TOP (100) *
FROM dbo.vw_InventoryInquiry_Type4;
GO

SELECT TOP (100) *
FROM dbo.vw_InventoryInquiry_TypeF;
GO
