/* ============================================================
   Why is Modality null on 84% of rows?
   Three questions, in the order that decides what to do.
   Read-only, aggregate only.
   ============================================================ */
USE MirthReporting;
GO
SET NOCOUNT ON;
GO

/* 1. Is it missing everywhere, or only for some sites?
      If TCH is populated and the others are not (or vice versa),
      the gap is a feed problem with a known owner. */
SELECT
    Site,
    rows          = COUNT(*),
    with_modality = SUM(CASE WHEN NULLIF(LTRIM(RTRIM(Modality)), '') IS NULL THEN 0 ELSE 1 END),
    pct_populated = CAST(100.0 * SUM(CASE WHEN NULLIF(LTRIM(RTRIM(Modality)), '') IS NULL THEN 0 ELSE 1 END)
                         / NULLIF(COUNT(*), 0) AS decimal(5,1))
FROM dbo.ReviewedStudyAudit
GROUP BY Site
ORDER BY rows DESC;


/* 2. Has it started being populated recently?
      If the nulls are all older rows, this fixes itself going
      forward and only the backfill is affected. */
SELECT
    review_date   = CAST(ReviewDateTime AS date),
    rows          = COUNT(*),
    with_modality = SUM(CASE WHEN NULLIF(LTRIM(RTRIM(Modality)), '') IS NULL THEN 0 ELSE 1 END),
    pct_populated = CAST(100.0 * SUM(CASE WHEN NULLIF(LTRIM(RTRIM(Modality)), '') IS NULL THEN 0 ELSE 1 END)
                         / NULLIF(COUNT(*), 0) AS decimal(5,1))
FROM dbo.ReviewedStudyAudit
GROUP BY CAST(ReviewDateTime AS date)
ORDER BY review_date DESC;


/* 3. Can modality be derived from the exam code?
      Substitute the exam/procedure column name from the column
      inventory (position 6 in the sample: IMG794, 507108).

      Rows returned = exam codes that map to MORE THAN ONE
      modality. If this comes back empty, the mapping is clean
      and a lookup can fill the nulls. If it is long, it cannot. */
-- SELECT TOP 30
--     exam_code  = <ExamCodeColumn>,
--     modalities = COUNT(DISTINCT Modality),
--     rows       = COUNT(*)
-- FROM dbo.ReviewedStudyAudit
-- WHERE NULLIF(LTRIM(RTRIM(Modality)), '') IS NOT NULL
-- GROUP BY <ExamCodeColumn>
-- HAVING COUNT(DISTINCT Modality) > 1
-- ORDER BY rows DESC;

/* 3b. And how much of the null population could a lookup actually
       cover — do the null rows' exam codes appear among the
       populated ones at all? */
-- SELECT
--     null_rows            = COUNT(*),
--     code_seen_elsewhere  = SUM(CASE WHEN k.<ExamCodeColumn> IS NULL THEN 0 ELSE 1 END),
--     pct_coverable        = CAST(100.0 * SUM(CASE WHEN k.<ExamCodeColumn> IS NULL THEN 0 ELSE 1 END)
--                                 / NULLIF(COUNT(*), 0) AS decimal(5,1))
-- FROM dbo.ReviewedStudyAudit n
-- LEFT JOIN (
--     SELECT DISTINCT <ExamCodeColumn>
--     FROM dbo.ReviewedStudyAudit
--     WHERE NULLIF(LTRIM(RTRIM(Modality)), '') IS NOT NULL
-- ) k ON k.<ExamCodeColumn> = n.<ExamCodeColumn>
-- WHERE NULLIF(LTRIM(RTRIM(n.Modality)), '') IS NULL;
