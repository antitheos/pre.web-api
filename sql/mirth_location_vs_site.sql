/* ============================================================
   Location vs Site — does the history problem actually exist?

   The 50-row sample's site codes (KMH, XRA, TJH, TCH...) are in
   column 3, `Location`. `Site` is column 11 and was NULL in every
   one of those rows. If Location is populated where Site is not,
   then site attribution is recoverable for the whole history and
   the "only three usable days" conclusion is wrong.

   Read-only, aggregate only.
   ============================================================ */
USE MirthReporting;
GO
SET NOCOUNT ON;
GO

/* 1. How complete is each of the two columns? */
SELECT
    rows          = COUNT(*),
    location_set  = SUM(CASE WHEN NULLIF(LTRIM(RTRIM(Location)), '') IS NULL THEN 0 ELSE 1 END),
    site_set      = SUM(CASE WHEN NULLIF(LTRIM(RTRIM(Site)),     '') IS NULL THEN 0 ELSE 1 END),
    neither_set   = SUM(CASE WHEN NULLIF(LTRIM(RTRIM(Location)), '') IS NULL
                             AND NULLIF(LTRIM(RTRIM(Site)),      '') IS NULL THEN 1 ELSE 0 END)
FROM dbo.ReviewedStudyAudit;


/* 2. Specifically: where Site is missing, is Location there?
      This is the one that decides how much history is usable. */
SELECT
    site_null_rows   = COUNT(*),
    with_location    = SUM(CASE WHEN NULLIF(LTRIM(RTRIM(Location)), '') IS NULL THEN 0 ELSE 1 END),
    pct_recoverable  = CAST(100.0 * SUM(CASE WHEN NULLIF(LTRIM(RTRIM(Location)), '') IS NULL THEN 0 ELSE 1 END)
                            / NULLIF(COUNT(*), 0) AS decimal(5,1))
FROM dbo.ReviewedStudyAudit
WHERE NULLIF(LTRIM(RTRIM(Site)), '') IS NULL;


/* 3. Where both are present, do they agree — or is Site a rollup
      of Location? Decides whether Location can simply stand in.

      If every pair is Location = Site, they are the same thing.
      If several Locations map to one Site, Site is a grouping and
      a Location -> Site lookup is needed for the older rows. */
SELECT
    Location,
    Site,
    rows = COUNT(*)
FROM dbo.ReviewedStudyAudit
WHERE NULLIF(LTRIM(RTRIM(Location)), '') IS NOT NULL
  AND NULLIF(LTRIM(RTRIM(Site)),     '') IS NOT NULL
GROUP BY Location, Site
ORDER BY rows DESC;


/* 4. And how many Sites does each Location map to? Anything
      greater than 1 means the mapping is not a clean lookup. */
SELECT
    Location,
    distinct_sites = COUNT(DISTINCT Site),
    rows           = COUNT(*)
FROM dbo.ReviewedStudyAudit
WHERE NULLIF(LTRIM(RTRIM(Location)), '') IS NOT NULL
  AND NULLIF(LTRIM(RTRIM(Site)),     '') IS NOT NULL
GROUP BY Location
HAVING COUNT(DISTINCT Site) > 1
ORDER BY rows DESC;
