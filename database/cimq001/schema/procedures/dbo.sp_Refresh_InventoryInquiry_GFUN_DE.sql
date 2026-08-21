USE [SAL_MRT];
GO


CREATE   PROCEDURE [dbo].[sp_Refresh_InventoryInquiry_GFUN_DE]
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE
          @StartedAt   DATETIME2(0) = SYSDATETIME()
        , @CompletedAt DATETIME2(0);

    /*
      執行順序不可更換：
      1. 目前庫存快照
      2. TLFS111 異動日期
      3. 生管／採購人員（依 cimq001a.4gl）
      4. 平均成本
    */
    EXEC dbo.sp_Load_InventoryInquirySnapshot_Core_GFUN_DE;
    EXEC dbo.sp_Load_InventoryInquiryActivity_GFUN_DE;

    EXEC dbo.sp_Update_InventoryInquiryPerson_GFUN_DE
         @AsOfDate = NULL,
         @OnlyMissing = 0,
         @MaxRows = NULL;

    EXEC dbo.sp_Update_InventoryInquiryCost_GFUN_DE;

    SET @CompletedAt = SYSDATETIME();

    SELECT
          N'GFUN' AS OperatingCenter
        , N'聚紡營運中心' AS OperatingCenterName
        , N'D,E' AS ItemTypeScope
        , @StartedAt AS StartedAt
        , @CompletedAt AS CompletedAt
        , DATEDIFF(SECOND, @StartedAt, @CompletedAt) AS ElapsedSeconds;
END;

GO
