/* ============================================================
   MirthReporting.dbo.ReviewedStudyAudit — profile
   Read-only. Returns schema, counts and distributions only:
   no accession, no patient identifier, no study-level row.

   Run 1-4 first; 4 is the one that decides whether the modality
   breakdown can be built at all.
   ============================================================ */

USE MirthReporting;
GO
SET NOCOUNT ON;
GO

/* ------------------------------------------------------------
   1. Real column names and types.
      Settles the names inferred from the headerless sample, and
      shows whether a modality column exists at all.
   ------------------------------------------------------------ */
SELECT
    c.ORDINAL_POSITION,
    c.COLUMN_NAME,
    c.DATA_TYPE,
    c.CHARACTER_MAXIMUM_LENGTH,
    c.IS_NULLABLE
FROM INFORMATION_SCHEMA.COLUMNS c
WHERE c.TABLE_SCHEMA = 'dbo'
  AND c.TABLE_NAME  = 'ReviewedStudyAudit'
ORDER BY c.ORDINAL_POSITION;


/* ------------------------------------------------------------
   2. Indexes and size. You control this database, so what is
      missing here is worth knowing — the loader will filter on
      an arrival column and bucket on ReviewDateTime.
   ------------------------------------------------------------ */
SELECT
    index_name  = i.name,
    i.type_desc,
    i.is_unique,
    i.is_primary_key,
    key_columns = STUFF((
        SELECT ', ' + c.name
        FROM sys.index_columns ic
        JOIN sys.columns c ON c.object_id = ic.object_id AND c.column_id = ic.column_id
        WHERE ic.object_id = i.object_id AND ic.index_id = i.index_id
          AND ic.is_included_column = 0
        ORDER BY ic.key_ordinal FOR XML PATH('')), 1, 2, ''),
    included = STUFF((
        SELECT ', ' + c.name
        FROM sys.index_columns ic
        JOIN sys.columns c ON c.object_id = ic.object_id AND c.column_id = ic.column_id
        WHERE ic.object_id = i.object_id AND ic.index_id = i.index_id
          AND ic.is_included_column = 1
        ORDER BY ic.index_column_id FOR XML PATH('')), 1, 2, '')
FROM sys.indexes i
WHERE i.object_id = OBJECT_ID('dbo.ReviewedStudyAudit')
  AND i.type_desc <> 'HEAP'
ORDER BY i.index_id;

SELECT
    approx_rows = SUM(p.rows),
    total_mb    = CAST(SUM(a.total_pages) * 8.0 / 1024 AS decimal(10,1))
FROM sys.partitions p
JOIN sys.allocation_units a ON a.container_id = p.partition_id
WHERE p.object_id = OBJECT_ID('dbo.ReviewedStudyAudit')
  AND p.index_id IN (0, 1);


/* ------------------------------------------------------------
   3. How much history, and how fast it grows.
      Decides whether a 4-month backfill is even possible.
   ------------------------------------------------------------ */
SELECT
    rows_total   = COUNT(*),
    accessions   = COUNT(DISTINCT AccessionNumber),
    first_review = MIN(ReviewDateTime),
    last_review  = MAX(ReviewDateTime),
    days_covered = DATEDIFF(day, MIN(ReviewDateTime), MAX(ReviewDateTime)) + 1
FROM dbo.ReviewedStudyAudit;

SELECT TOP 14
    review_date = CAST(ReviewDateTime AS date),
    rows        = COUNT(*),
    accessions  = COUNT(DISTINCT AccessionNumber)
FROM dbo.ReviewedStudyAudit
GROUP BY CAST(ReviewDateTime AS date)
ORDER BY review_date DESC;


/* ------------------------------------------------------------
   4. THE ONE THAT MATTERS: what is actually in Modality?
      Nothing in the 50-row sample looked like a modality code,
      which would send every row into the "Other" bucket.
      If this errors with an invalid column, the column does not
      exist and modality has to come from somewhere else.
   ------------------------------------------------------------ */
SELECT TOP 40
    Modality,
    rows = COUNT(*)
FROM dbo.ReviewedStudyAudit
GROUP BY Modality
ORDER BY rows DESC;


/* ------------------------------------------------------------
   5. Vocabularies. Small columns, safe to list in full.
   ------------------------------------------------------------ */
SELECT Site, rows = COUNT(*), accessions = COUNT(DISTINCT AccessionNumber)
FROM dbo.ReviewedStudyAudit
GROUP BY Site
ORDER BY rows DESC;

SELECT StudyStatus, rows = COUNT(*)
FROM dbo.ReviewedStudyAudit
GROUP BY StudyStatus
ORDER BY rows DESC;

/* Priority looked like ROUTINE / STAT at position 8. Substitute
   the real name from query 1 if it differs. */
-- SELECT <PriorityColumn>, rows = COUNT(*)
-- FROM dbo.ReviewedStudyAudit
-- GROUP BY <PriorityColumn> ORDER BY rows DESC;


/* ------------------------------------------------------------
   6. Duplication. The sample was 20% duplicate rows, which is
      why the report deduplicates by accession. This sizes it
      across the whole table without returning any accession.
   ------------------------------------------------------------ */
WITH PerAccession AS (
    SELECT AccessionNumber, rows_for_accession = COUNT(*)
    FROM dbo.ReviewedStudyAudit
    WHERE StudyStatus = 'REVIEWED'
    GROUP BY AccessionNumber
)
SELECT
    rows_for_accession,
    accessions = COUNT(*),
    extra_rows = SUM(rows_for_accession - 1)
FROM PerAccession
GROUP BY rows_for_accession
ORDER BY rows_for_accession;

/* Headline: how far off would a naive COUNT(*) be? */
SELECT
    raw_rows        = COUNT(*),
    distinct_accns  = COUNT(DISTINCT AccessionNumber),
    overcount_pct   = CAST(100.0 * (COUNT(*) - COUNT(DISTINCT AccessionNumber))
                           / NULLIF(COUNT(*), 0) AS decimal(5,1))
FROM dbo.ReviewedStudyAudit
WHERE StudyStatus = 'REVIEWED';


/* ------------------------------------------------------------
   7. Late arrival. The sample had rows inserted up to 34 hours
      after their review time, which a trailing window on
      ReviewDateTime would miss entirely.

      Substitute the real arrival column from query 1 for
      <InsertedColumn> (position 10 in the sample).
   ------------------------------------------------------------ */
-- SELECT
--     lag_bucket = CASE
--         WHEN DATEDIFF(second, ReviewDateTime, <InsertedColumn>) < 60      THEN '< 1 min'
--         WHEN DATEDIFF(second, ReviewDateTime, <InsertedColumn>) < 3600    THEN '< 1 hour'
--         WHEN DATEDIFF(second, ReviewDateTime, <InsertedColumn>) < 10800   THEN '1-3 hours'
--         WHEN DATEDIFF(second, ReviewDateTime, <InsertedColumn>) < 86400   THEN '3-24 hours'
--         ELSE '> 24 hours' END,
--     rows = COUNT(*)
-- FROM dbo.ReviewedStudyAudit
-- GROUP BY CASE
--         WHEN DATEDIFF(second, ReviewDateTime, <InsertedColumn>) < 60      THEN '< 1 min'
--         WHEN DATEDIFF(second, ReviewDateTime, <InsertedColumn>) < 3600    THEN '< 1 hour'
--         WHEN DATEDIFF(second, ReviewDateTime, <InsertedColumn>) < 10800   THEN '1-3 hours'
--         WHEN DATEDIFF(second, ReviewDateTime, <InsertedColumn>) < 86400   THEN '3-24 hours'
--         ELSE '> 24 hours' END
-- ORDER BY rows DESC;


/* ------------------------------------------------------------
   8. Is Id monotonic with arrival? If so it is a clean
      high-water mark for the incremental loader.
   ------------------------------------------------------------ */
SELECT edge = 'lowest Id',  ReviewDateTime FROM (SELECT TOP 1 ReviewDateTime FROM dbo.ReviewedStudyAudit ORDER BY Id ASC)  a
UNION ALL
SELECT edge = 'highest Id', ReviewDateTime FROM (SELECT TOP 1 ReviewDateTime FROM dbo.ReviewedStudyAudit ORDER BY Id DESC) b;
