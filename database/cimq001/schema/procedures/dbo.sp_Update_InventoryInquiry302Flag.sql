USE [SAL_MRT];
GO


CREATE   PROCEDURE dbo.sp_Update_InventoryInquiry302Flag
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE
          @StartedAt    DATETIME2(0) = SYSDATETIME()
        , @CompletedAt  DATETIME2(0)
        , @UpdatedRows  BIGINT = 0
        , @LockResult   INT;

    /*
    ===============================================================================
    dbo.sp_Update_InventoryInquiry302Flag

    目的：
        更新 dbo.InventoryInquirySnapshot.Project302Flag

    判斷規則：
        1. OperatingCenter = 'M302'                -> Y
        2. 其他營運中心 imgs04 LIKE 'A1132%'      -> Y
        3. 其他營運中心 imgs04 LIKE 'A3132%'      -> Y
        4. 其他                                    -> N

    說明：
        - M302 為 302 營運中心，因此該營運中心所有庫存皆視為 302 專案。
        - SNX / GFUN 等其他營運中心保留原本批號判斷邏輯。
        - 只更新既有 InventoryInquirySnapshot，不重載庫存。
    ===============================================================================
    */

    /*============================================================
      1. 防止同時重複執行
    ============================================================*/
    EXEC @LockResult = sys.sp_getapplock
          @Resource = N'SAL_MRT.InventoryInquiry.Project302Flag'
        , @LockMode = N'Exclusive'
        , @LockOwner = N'Session'
        , @LockTimeout = 0;

    IF @LockResult < 0
    BEGIN
        THROW 50301, N'302 專案判斷目前正在執行中。', 1;
    END;

    BEGIN TRY

        /*============================================================
          2. 基本檢查
        ============================================================*/
        IF OBJECT_ID(N'dbo.InventoryInquirySnapshot', N'U') IS NULL
        BEGIN
            THROW 50302,
                  N'dbo.InventoryInquirySnapshot 資料表不存在。',
                  1;
        END;

        IF COL_LENGTH(
               N'dbo.InventoryInquirySnapshot',
               N'Project302Flag'
           ) IS NULL
        BEGIN
            THROW 50303,
                  N'InventoryInquirySnapshot 缺少 Project302Flag 欄位。',
                  1;
        END;

        IF COL_LENGTH(
               N'dbo.InventoryInquirySnapshot',
               N'imgs04'
           ) IS NULL
        BEGIN
            THROW 50304,
                  N'InventoryInquirySnapshot 缺少 imgs04 欄位。',
                  1;
        END;

        IF COL_LENGTH(
               N'dbo.InventoryInquirySnapshot',
               N'OperatingCenter'
           ) IS NULL
        BEGIN
            THROW 50306,
                  N'InventoryInquirySnapshot 缺少 OperatingCenter 欄位，無法判斷 M302。',
                  1;
        END;

        IF NOT EXISTS
        (
            SELECT 1
            FROM dbo.InventoryInquirySnapshot
        )
        BEGIN
            THROW 50305,
                  N'InventoryInquirySnapshot 尚無資料。',
                  1;
        END;

        /*============================================================
          3. 更新 302 專案旗標
        ============================================================*/
        BEGIN TRANSACTION;

        UPDATE s
        SET s.Project302Flag =
            CASE
                /* M302 營運中心全部都是 302 專案 */
                WHEN UPPER(
                         LTRIM(
                             RTRIM(
                                 ISNULL(
                                     CONVERT(NVARCHAR(50), s.OperatingCenter),
                                     N''
                                 )
                             )
                         )
                     ) = N'M302'
                    THEN N'Y'

                /* 其他營運中心沿用原批號規則 */
                WHEN UPPER(
                         LTRIM(
                             RTRIM(
                                 ISNULL(
                                     CONVERT(NVARCHAR(100), s.imgs04),
                                     N''
                                 )
                             )
                         )
                     ) LIKE N'A1132%'
                  OR UPPER(
                         LTRIM(
                             RTRIM(
                                 ISNULL(
                                     CONVERT(NVARCHAR(100), s.imgs04),
                                     N''
                                 )
                             )
                         )
                     ) LIKE N'A3132%'
                    THEN N'Y'

                ELSE N'N'
            END
        FROM dbo.InventoryInquirySnapshot AS s;

        SET @UpdatedRows = @@ROWCOUNT;

        COMMIT TRANSACTION;

        SET @CompletedAt = SYSDATETIME();

        /*============================================================
          4. 結果 1：依營運中心顯示 Y / N 筆數
        ============================================================*/
        SELECT
              ISNULL(
                  NULLIF(
                      LTRIM(RTRIM(CONVERT(NVARCHAR(50), OperatingCenter))),
                      N''
                  ),
                  N'<NULL>'
              ) AS OperatingCenter
            , Project302Flag
            , COUNT_BIG(*) AS RecordCount
            , SUM(
                  TRY_CONVERT(
                      DECIMAL(38,6),
                      ISNULL(imgs08, 0)
                  )
              ) AS InventoryQuantity
        FROM dbo.InventoryInquirySnapshot
        GROUP BY
              ISNULL(
                  NULLIF(
                      LTRIM(RTRIM(CONVERT(NVARCHAR(50), OperatingCenter))),
                      N''
                  ),
                  N'<NULL>'
              )
            , Project302Flag
        ORDER BY
              OperatingCenter
            , Project302Flag;

        /*============================================================
          5. 結果 2：實際被判定為 302 的資料分布
        ============================================================*/
        SELECT
              ISNULL(
                  NULLIF(
                      LTRIM(RTRIM(CONVERT(NVARCHAR(50), OperatingCenter))),
                      N''
                  ),
                  N'<NULL>'
              ) AS OperatingCenter
            , CONVERT(NVARCHAR(100), imgs04) AS imgs04
            , ta_ima01 AS ItemType
            , COUNT_BIG(*) AS RecordCount
            , SUM(
                  TRY_CONVERT(
                      DECIMAL(38,6),
                      ISNULL(imgs08, 0)
                  )
              ) AS InventoryQuantity
        FROM dbo.InventoryInquirySnapshot
        WHERE Project302Flag = N'Y'
        GROUP BY
              ISNULL(
                  NULLIF(
                      LTRIM(RTRIM(CONVERT(NVARCHAR(50), OperatingCenter))),
                      N''
                  ),
                  N'<NULL>'
              )
            , CONVERT(NVARCHAR(100), imgs04)
            , ta_ima01
        ORDER BY
              OperatingCenter
            , imgs04
            , ta_ima01;

        /*============================================================
          6. 驗證：M302 不允許存在 N
        ============================================================*/
        SELECT
              COUNT_BIG(*) AS M302TotalRows
            , SUM(
                  CASE
                      WHEN Project302Flag = N'Y' THEN 1
                      ELSE 0
                  END
              ) AS M302YRows
            , SUM(
                  CASE
                      WHEN ISNULL(Project302Flag, N'N') <> N'Y' THEN 1
                      ELSE 0
                  END
              ) AS M302NotYRows
        FROM dbo.InventoryInquirySnapshot
        WHERE UPPER(
                  LTRIM(
                      RTRIM(
                          ISNULL(
                              CONVERT(NVARCHAR(50), OperatingCenter),
                              N''
                          )
                      )
                  )
              ) = N'M302';

        /*============================================================
          7. 執行資訊
        ============================================================*/
        SELECT
              @UpdatedRows AS UpdatedRows
            , @StartedAt AS StartedAt
            , @CompletedAt AS CompletedAt
            , DATEDIFF(
                  SECOND,
                  @StartedAt,
                  @CompletedAt
              ) AS ElapsedSeconds;

        EXEC sys.sp_releaseapplock
              @Resource = N'SAL_MRT.InventoryInquiry.Project302Flag'
            , @LockOwner = N'Session';

    END TRY
    BEGIN CATCH

        IF @@TRANCOUNT > 0
            ROLLBACK TRANSACTION;

        EXEC sys.sp_releaseapplock
              @Resource = N'SAL_MRT.InventoryInquiry.Project302Flag'
            , @LockOwner = N'Session';

        THROW;

    END CATCH;
END;

GO
