USE [SAL_MRT];
GO

CREATE TABLE [dbo].[InventoryInquiryActivityLoadState]
(
    [ProcessName] sysname NOT NULL,
    [BackfillBeforeDate] date NULL,
    [OracleMinDate] date NULL,
    [BackfillComplete] bit NOT NULL CONSTRAINT [DF_InventoryActivityState_Complete] DEFAULT ((0)),
    [LastSourceRows] bigint NULL,
    [LastInsertedRows] bigint NULL,
    [LastSuccessfulAt] datetime2(0) NULL,
    CONSTRAINT [PK_InventoryInquiryActivityLoadState] PRIMARY KEY CLUSTERED ([ProcessName] ASC)
);
GO

