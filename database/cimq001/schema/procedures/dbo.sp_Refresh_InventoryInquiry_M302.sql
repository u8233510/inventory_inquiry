USE [SAL_MRT];
GO


CREATE   PROCEDURE [dbo].[sp_Refresh_InventoryInquiry_M302]
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE
          @StartedAt   DATETIME2(0) = SYSDATETIME()
        , @CompletedAt DATETIME2(0);

    /*
      執行順序不可更換：
      1. M302 目前庫存快照
      2. M302 TLFS12 異動日期
      3. M302 生管／採購人員（依 cimq001.4gl）
      4. M302 平均成本
    */
    EXEC dbo.sp_Load_InventoryInquirySnapshot_Core_M302;
    EXEC dbo.sp_Load_InventoryInquiryActivity_M302;

    EXEC dbo.sp_Update_InventoryInquiryPerson_M302
         @AsOfDate = NULL,
         @OnlyMissing = 0,
         @MaxRows = NULL;

    EXEC dbo.sp_Update_InventoryInquiryCost_M302;

    SET @CompletedAt = SYSDATETIME();

    SELECT
          N'M302' AS OperatingCenter
        , N'非D,E' AS ItemTypeScope
        , @StartedAt AS StartedAt
        , @CompletedAt AS CompletedAt
        , DATEDIFF(SECOND, @StartedAt, @CompletedAt) AS ElapsedSeconds;
END;

GO
