/* ============================================================
   dbo.pri_site_volume        (MirthReporting)

   Reviewed study volume by site, modality and hour, split into
   STAT / Routine / Other, which sum to Total. Replaces
   pri_site_daily_ingest, which
   read peerVue and counted cases; this counts deduplicated
   accessions from the reporting table.

   Grain: siteGroup x modality x activityHourUtc. Counts only —
   no accession, no order number, no patient identifier leaves
   this proc. Aggregation happens here and nowhere downstream.

   TIME ZONE. ReviewDateTime is a naive datetime on the server's
   local clock, confirmed Eastern on 2026-09-02 (max review 0
   minutes behind local, 240 behind UTC). Parameters are UTC and
   output is UTC; Eastern is applied only at render. Window
   parameters convert UTC -> local once so predicates stay
   seekable against IX_ReviewedStudyAudit_Date_Location.
   ============================================================ */

USE MirthReporting;
GO

CREATE OR ALTER PROCEDURE dbo.pri_site_volume
    @FromDateUtc datetime2(0) = NULL,
    @ToDateUtc   datetime2(0) = NULL
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @sourceZone sysname = 'Eastern Standard Time';

    /* No window means the whole table, and that is the intended
       default. Rows arrive late by weeks, not hours: the earliest
       review is 2026-07-27 while the lowest Id carries a review
       date of 2026-08-18, so a trailing window on review time
       would silently lose back-loaded batches. The table is 4.6 MB
       and grows about 2,400 rows a day, so recomputing all of it
       costs almost nothing and removes the whole class of bug.

       Revisit if the table passes roughly a million rows; the fix
       then is an Id high-water mark plus recomputation of every
       hour those new rows touch, not a narrower date window. */
    DECLARE @FromLocal datetime2(0) =
        CASE WHEN @FromDateUtc IS NULL THEN NULL
             ELSE CAST(@FromDateUtc AT TIME ZONE 'UTC' AT TIME ZONE @sourceZone AS datetime2(0)) END;
    DECLARE @ToLocal datetime2(0) =
        CASE WHEN @ToDateUtc IS NULL THEN NULL
             ELSE CAST(@ToDateUtc   AT TIME ZONE 'UTC' AT TIME ZONE @sourceZone AS datetime2(0)) END;

    ;WITH LocationRanked AS
    (
        /* Site is a rollup of Location, and Site is null on 34% of
           rows while Location is present on 99.99%. This derives
           the Location -> Site map from the rows that carry both,
           so the older rows can be attributed rather than dropped.

           Majority wins where a Location maps to several Sites.
           Only seven Locations do, and only 117 rows sit on the
           wrong side of that call — 112 of them 'DISCHARGED',
           which maps to thirteen Sites and is a patient status in
           a location field rather than a location. Change the
           HAVING below to exclude it if that is preferred. */
        SELECT
            Location,
            Site,
            rows = COUNT(*),
            rn   = ROW_NUMBER() OVER (PARTITION BY Location ORDER BY COUNT(*) DESC, Site)
        FROM dbo.ReviewedStudyAudit
        WHERE NULLIF(LTRIM(RTRIM(Location)), '') IS NOT NULL
          AND NULLIF(LTRIM(RTRIM(Site)),     '') IS NOT NULL
        GROUP BY Location, Site
    ),
    LocationMap AS
    (
        SELECT Location, Site FROM LocationRanked WHERE rn = 1
    ),
    Ranked AS
    (
        /* Dedup by accession, ranked over the WHOLE table — never
           inside the output window. The report counts a study once,
           at its first review; ranking within a window would let a
           repeat review inside it look like a first review and
           over-count. 24.8% of rows are duplicates, so this is the
           load-bearing part of the query. */
        SELECT
            a.ReviewDateTime,
            priority = UPPER(LTRIM(RTRIM(a.Priority))),
            modality = UPPER(LTRIM(RTRIM(a.Modality))),
            siteRaw  = COALESCE(NULLIF(LTRIM(RTRIM(a.Site)), ''), m.Site),
            rn       = ROW_NUMBER() OVER (
                           PARTITION BY a.AccessionNumber
                           ORDER BY a.ReviewDateTime, a.Id)
        FROM dbo.ReviewedStudyAudit a
        LEFT JOIN LocationMap m ON m.Location = a.Location
        WHERE a.StudyStatus = 'REVIEWED'
    ),
    FirstReviewed AS
    (
        SELECT
            ReviewDateTime,
            priority,
            /* TCH is matched by name; everything else rolls up to
               Mercy, including the TJHZ* departments. Rollup with a
               catch-all, approved 2026-09-02. */
            siteGroup = CASE WHEN siteRaw = 'TCH' THEN 'TCH' ELSE 'Mercy' END,
            /* Buckets as specified. Modality is null before
               2026-08-31 and lands in Other for that period; XA, PT
               and OT are real values that also bucket to Other. */
            modalityBucket = CASE
                WHEN modality = 'CT' THEN 'CT'
                WHEN modality = 'MR' THEN 'MR'
                WHEN modality = 'US' THEN 'US'
                WHEN modality IN ('CR', 'DX', 'XR') THEN 'XR'
                WHEN modality = 'NM' THEN 'NM'
                WHEN modality = 'MG' THEN 'MG'
                WHEN modality = 'RF' THEN 'RF'
                ELSE 'Other' END
        FROM Ranked
        WHERE rn = 1
    ),
    Windowed AS
    (
        SELECT *
        FROM FirstReviewed
        WHERE (@FromLocal IS NULL OR ReviewDateTime >= @FromLocal)
          AND (@ToLocal   IS NULL OR ReviewDateTime <  @ToLocal)
    )
    SELECT
        siteName = siteGroup,
        modality = modalityBucket,
        /* Canonical bucket: the UTC instant the hour starts at.
           This is the key downstream. */
        activityHourUtc = DATEADD(hour, DATEDIFF(hour, 0, tsUtc), 0),
        activityDateUtc = CAST(tsUtc AS date),
        activityHour    = DATEPART(hour, tsUtc),

        statCount    = SUM(CASE WHEN priority = 'STAT'    THEN 1 ELSE 0 END),
        routineCount = SUM(CASE WHEN priority = 'ROUTINE' THEN 1 ELSE 0 END),
        /* Anything that is neither, including a null priority.
           Measured 2026-09-02: WET READ 941, MEDIUM 111, LOW 19 —
           1,071 rows, 2.53% of the table, so this is NOT zero and
           the chart stacks it as a third band. Without it the bars
           would fall short of their own labelled total. */
        otherCount   = SUM(CASE WHEN priority NOT IN ('STAT', 'ROUTINE')
                                  OR priority IS NULL THEN 1 ELSE 0 END),
        totalCount   = COUNT(*)
    FROM (
        SELECT
            siteGroup, modalityBucket, priority,
            tsUtc = CAST(ReviewDateTime AT TIME ZONE @sourceZone AT TIME ZONE 'UTC' AS datetime2(0))
        FROM Windowed
    ) x
    GROUP BY
        siteGroup,
        modalityBucket,
        DATEADD(hour, DATEDIFF(hour, 0, tsUtc), 0),
        CAST(tsUtc AS date),
        DATEPART(hour, tsUtc)
    ORDER BY activityHourUtc, siteName, modality;
END
GO

/* ------------------------------------------------------------
   Notes.

   STAT + Routine + Other = Total, by construction, and the chart
   stacks all three. The Priority vocabulary was measured on
   2026-09-02: ROUTINE 22,496; STAT 18,777; WET READ 941;
   MEDIUM 111; LOW 19. Everything after the first two lands in
   Other — 2.53% of rows, of which 88% is WET READ. Kept as its
   own band rather than folded into STAT, which would have been a
   clinical judgement rather than a reporting one.

   MODALITY is null before 2026-08-31 and everything from that
   period buckets to Other. Site and priority are unaffected and
   are usable across the whole table.

   INDEXES. IX_ReviewedStudyAudit_Date_Location covers
   (ReviewDateTime, Location); the PK is clustered on Id. Nothing
   indexes Site, Modality or Priority, and nothing needs to at
   this size.
   ------------------------------------------------------------ */

/* Whole table — the loader's normal call.
EXEC dbo.pri_site_volume;
*/

/* A window, for spot checks. UTC bounds.
EXEC dbo.pri_site_volume '2026-09-01T04:00:00', '2026-09-03T04:00:00';
*/
