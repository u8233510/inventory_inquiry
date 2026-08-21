USE [SAL_MRT];
GO

CREATE TABLE [dbo].[InventoryInquiryActivity]
(
    [ActivityId] bigint IDENTITY(1,1) NOT NULL,
    [InventoryKey] varbinary(32) NOT NULL,
    [ActivityDate] date NOT NULL,
    [ActivityType] varchar(10) NOT NULL,
    [ItemNo] nvarchar(100) NULL,
    [WarehouseNo] nvarchar(50) NULL,
    [LocationNo] nvarchar(50) NULL,
    [LotNo] nvarchar(100) NULL,
    [SerialNo] nvarchar(100) NULL,
    [ManufacturingLotNo] nvarchar(100) NULL,
    [LoadBatchId] uniqueidentifier NOT NULL,
    [LoadedAt] datetime2(0) NOT NULL CONSTRAINT [DF_InventoryInquiryActivity_LoadedAt] DEFAULT (sysdatetime()),
    [OperatingCenter] nvarchar(20) NULL,
    CONSTRAINT [PK_InventoryInquiryActivity] PRIMARY KEY CLUSTERED ([ActivityId] ASC)
);
GO

CREATE NONCLUSTERED INDEX [IX_InventoryInquiryActivity_Date] ON [dbo].[InventoryInquiryActivity] ([ActivityDate] ASC, [InventoryKey] ASC) INCLUDE ([ActivityType]);
GO
CREATE NONCLUSTERED INDEX [IX_InventoryInquiryActivity_Key] ON [dbo].[InventoryInquiryActivity] ([InventoryKey] ASC, [ActivityDate] ASC) INCLUDE ([ActivityType]);
GO
CREATE UNIQUE NONCLUSTERED INDEX [UX_InventoryInquiryActivity_KeyDateType] ON [dbo].[InventoryInquiryActivity] ([InventoryKey] ASC, [ActivityDate] ASC, [ActivityType] ASC);
GO
