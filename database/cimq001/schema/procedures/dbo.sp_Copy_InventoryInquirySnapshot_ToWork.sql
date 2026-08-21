USE [SAL_MRT];
GO


CREATE   PROCEDURE dbo.sp_Copy_InventoryInquirySnapshot_ToWork
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE
          @SourceRows     BIGINT
        , @WorkRows       BIGINT
        , @ColumnList     NVARCHAR(MAX)
        , @Sql            NVARCHAR(MAX)
        , @LockResult     INT
        , @StartedAt      DATETIME2(0) = SYSDATETIME()
        , @CompletedAt    DATETIME2(0);

    /*
      防止同一時間重複發布。
    */
    EXEC @LockResult = sys.sp_getapplock
          @Resource = N'SAL_MRT.InventoryInquirySnapshot.CopyToWork'
        , @LockMode = N'Exclusive'
        , @LockOwner = N'Session'
        , @LockTimeout = 0;

    IF @LockResult < 0
    BEGIN
        THROW 50101,
              N'InventoryInquirySnapshot 正在複製到 Work，不能重複執行。',
              1;
    END;

    BEGIN TRY
        /*
          確認來源表存在。
        */
        IF OBJECT_ID
        (
            N'dbo.InventoryInquirySnapshot',
            N'U'
        ) IS NULL
        BEGIN
            THROW 50102,
                  N'dbo.InventoryInquirySnapshot 不存在。',
                  1;
        END;

        /*
          確認 Work 表存在。
        */
        IF OBJECT_ID
        (
            N'dbo.InventoryInquirySnapshot_Work',
            N'U'
        ) IS NULL
        BEGIN
            THROW 50103,
                  N'dbo.InventoryInquirySnapshot_Work 不存在。',
                  1;
        END;

        /*
          正式 Snapshot 不可為空，避免錯誤發布空資料。
        */
        SELECT
            @SourceRows = COUNT_BIG(*)
        FROM dbo.InventoryInquirySnapshot;

        IF ISNULL(@SourceRows, 0) = 0
        BEGIN
            THROW 50104,
                  N'InventoryInquirySnapshot 為空，不允許複製到 Work。',
                  1;
        END;

        /*
          取得兩張表共同的非 Identity、非計算欄位。

          SnapshotRowId 為流水號，不需強制複製相同值；
          Work 表會自行產生新的 SnapshotRowId。
        */
        SELECT
            @ColumnList =
                STRING_AGG
                (
                    CONVERT
                    (
                        NVARCHAR(MAX),
                        QUOTENAME(src.name)
                    ),
                    N','
                ) WITHIN GROUP
                  (
                      ORDER BY src.column_id
                  )
        FROM sys.columns AS src
        INNER JOIN sys.columns AS dst
            ON dst.object_id =
               OBJECT_ID
               (
                   N'dbo.InventoryInquirySnapshot_Work'
               )
           AND dst.name = src.name
           AND dst.is_identity = 0
           AND dst.is_computed = 0
        WHERE src.object_id =
              OBJECT_ID
              (
                  N'dbo.InventoryInquirySnapshot'
              )
          AND src.is_identity = 0
          AND src.is_computed = 0;

        IF NULLIF(@ColumnList, N'') IS NULL
        BEGIN
            THROW 50105,
                  N'找不到 Snapshot 與 Work 的共同欄位。',
                  1;
        END;

        BEGIN TRANSACTION;

        /*
          在同一個交易內清空並重新複製。

          複製完成前，其他查詢不會取得一張永久空白的 Work 表；
          若過程失敗，交易會回復。
        */
        TRUNCATE TABLE dbo.InventoryInquirySnapshot_Work;

        SET @Sql =
              N'INSERT INTO dbo.InventoryInquirySnapshot_Work'
            + N'('
            + @ColumnList
            + N') '
            + N'SELECT '
            + @ColumnList
            + N' FROM dbo.InventoryInquirySnapshot;';

        EXEC sys.sp_executesql @Sql;

        SELECT
            @WorkRows = COUNT_BIG(*)
        FROM dbo.InventoryInquirySnapshot_Work;

        /*
          發布前後筆數必須一致。
        */
        IF @WorkRows <> @SourceRows
        BEGIN
            THROW 50106,
                  N'Snapshot 與 Snapshot_Work 筆數不一致，發布取消。',
                  1;
        END;

        COMMIT TRANSACTION;

        SET @CompletedAt = SYSDATETIME();

        EXEC sys.sp_releaseapplock
              @Resource =
                  N'SAL_MRT.InventoryInquirySnapshot.CopyToWork'
            , @LockOwner = N'Session';

        SELECT
              @SourceRows AS SnapshotRows
            , @WorkRows AS WorkRows
            , @StartedAt AS StartedAt
            , @CompletedAt AS CompletedAt
            , DATEDIFF
              (
                  SECOND,
                  @StartedAt,
                  @CompletedAt
              ) AS ElapsedSeconds
            , N'複製成功' AS Result;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0
            ROLLBACK TRANSACTION;

        EXEC sys.sp_releaseapplock
              @Resource =
                  N'SAL_MRT.InventoryInquirySnapshot.CopyToWork'
            , @LockOwner = N'Session';

        THROW;
    END CATCH;
END;

GO
