/* ============================================================
   What time zone is MirthReporting in?

   The pipeline is UTC in, UTC out, with Eastern applied only at
   render. ReviewDateTime is a naive datetime, so it carries no
   zone of its own and the proc has to be told which one to
   interpret it as. Getting this wrong shifts every hourly bucket
   by four or five hours -- silently, and plausibly.

   Read-only. Returns clock readings only.
   ============================================================ */
USE MirthReporting;
GO
SET NOCOUNT ON;
GO

/* 1. What the server thinks the time is, three ways.
      product_version: 13 = 2016, 14 = 2017, 15 = 2019, 16 = 2022.
      AT TIME ZONE needs 2016 or later. */
SELECT
    product_version = CAST(SERVERPROPERTY('ProductVersion') AS varchar(50)),
    server_offset   = SYSDATETIMEOFFSET(),
    server_local    = GETDATE(),
    server_utc      = GETUTCDATE();


/* 2. THE DECIDING ONE: is ReviewDateTime on the server's local
      clock, or on UTC?

      Whichever of the two "behind" columns is near zero names the
      zone. If the data is current:

        ReviewDateTime is LOCAL  -> mins_behind_local  ~ 0
                                    mins_behind_utc    ~ +240 or +300
        ReviewDateTime is UTC    -> mins_behind_local  ~ -240 or -300
                                    mins_behind_utc    ~ 0

      A number near neither means the feed is simply stale; check
      max_review against the current time before concluding. */
DECLARE @max_review datetime2(7) =
    (SELECT MAX(ReviewDateTime) FROM dbo.ReviewedStudyAudit);

SELECT
    max_review        = @max_review,
    server_local      = GETDATE(),
    server_utc        = GETUTCDATE(),
    mins_behind_local = DATEDIFF(minute, @max_review, GETDATE()),
    mins_behind_utc   = DATEDIFF(minute, @max_review, GETUTCDATE());


/* 3. Is the server actually on Eastern, as opposed to some other
      zone that happens to share today's offset? Atlantic sits at
      -04:00 all year and would look identical in summer.

      If eastern_now matches server_offset, the server is Eastern.
      Requires SQL Server 2016+; skip if query 1 shows older. */
SELECT
    server_offset = SYSDATETIMEOFFSET(),
    eastern_now   = SYSDATETIME() AT TIME ZONE 'Eastern Standard Time',
    offsets_match = CASE
        WHEN DATEPART(tz, SYSDATETIMEOFFSET())
           = DATEPART(tz, SYSDATETIME() AT TIME ZONE 'Eastern Standard Time')
        THEN 'yes - server is Eastern'
        ELSE 'NO - server is not on Eastern' END;


/* 4. Sanity check on the arrival column, once its name is known
      from the column inventory. Both columns should be on the
      same clock: the sample showed a median lag of about one
      second, so a median near 240 or 300 minutes would mean one
      is UTC and the other local.

      Substitute the real column for <InsertedColumn>. */
-- SELECT
--     rows          = COUNT(*),
--     median_lag_s  = MIN(lag_s),   -- crude: run with the percentile below if needed
--     min_lag_s     = MIN(lag_s),
--     max_lag_s     = MAX(lag_s)
-- FROM (
--     SELECT lag_s = DATEDIFF(second, ReviewDateTime, <InsertedColumn>)
--     FROM dbo.ReviewedStudyAudit
--     WHERE ReviewDateTime >= DATEADD(day, -2, GETDATE())
-- ) x;
