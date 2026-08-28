/* ============================================================
   dbo.pri_site_daily_ingest

   Ingested volume by site — how many studies came in the door,
   whether or not we created a result.

   Grain of the result set: siteName x activityHourUtc x modality.
   Counts only. No study-level rows, no accession, no MRN, no
   timestamp finer than the hour. Aggregation happens HERE and
   nowhere downstream — see the health-data constraint in the task
   register.

   Measures come from event timestamps on Qi_AssignedCases:
       createdCount   CreatedDate   (NOT NULL)
       assignedCount  AssignedDate  (NOT NULL)
       reviewedCount  ReviewedDate  (NULL until reviewed)

   Population filters are the client's, unchanged: PacsID, the per-
   site role lists, TCH's modality allow-list, ToQiSpaceId = 15
   (confirmed = "Interpretation").

   Current-state filters (CaseStatus = 1, ExamStatus = 'REVIEWED')
   are deliberately NOT applied here, per the asker 2026-08-27.
   They remain in pri_site_status and pri_site_modality_status,
   which report live backlog and are the right place for them.

   TIME ZONE. Everything in and out of this proc is UTC. The stored
   columns are naive `datetime` in server-local time, so the proc
   converts at both edges: parameters UTC -> local (once, so the
   window predicates stay index-seekable), and output local -> UTC
   (per row, on the small qualifying set). Presentation in Eastern
   is the front end's job — see the notes at the bottom.
   ============================================================ */

CREATE OR ALTER PROCEDURE dbo.pri_site_daily_ingest
    @FromDateUtc datetime2(0) = NULL,
    @ToDateUtc   datetime2(0) = NULL
AS
BEGIN
    SET NOCOUNT ON;

    /* The zone the naive datetime columns are stored in. Single
       point of change if the DB server ever moves. Verify with:
           SELECT SYSDATETIMEOFFSET();
       Windows zone id; covers both EST and EDT. */
    DECLARE @serverZone sysname = 'Eastern Standard Time';

    /* Default window is the last completed UTC hour. The hourly
       loader normally passes an explicit trailing window (it
       upserts, so re-covering recent hours is safe and picks up
       late arrivals). */
    IF @ToDateUtc IS NULL
        SET @ToDateUtc = DATEADD(hour, DATEDIFF(hour, 0, SYSUTCDATETIME()), 0);
    IF @FromDateUtc IS NULL
        SET @FromDateUtc = DATEADD(hour, -1, @ToDateUtc);

    /* Convert the window to server-local ONCE. Doing this here
       rather than per row is what keeps the date predicates below
       seekable — wrapping a column in AT TIME ZONE would force a
       scan of all 6.35M rows of Qi_AssignedCases. */
    DECLARE @FromLocal datetime2(0) =
        CAST(@FromDateUtc AT TIME ZONE 'UTC' AT TIME ZONE @serverZone AS datetime2(0));
    DECLARE @ToLocal   datetime2(0) =
        CAST(@ToDateUtc   AT TIME ZONE 'UTC' AT TIME ZONE @serverZone AS datetime2(0));

    /* The window is half-open: [@From, @To). Consecutive hourly
       calls must not both claim the boundary instant. */

    ;WITH pop AS
    (
        /* ---------- Mercy (PacsID 4 = "Mercy Prod") ---------- */
        SELECT
            siteName        = 'Mercy',
            A.AssignedCaseId,
            modality        = ISNULL(H.Modality, '(none)'),
            A.CreatedDate,
            A.AssignedDate,
            A.ReviewedDate
        FROM Qi_AssignedCases A
        LEFT JOIN HL7StudyOLD H
               ON H.HL7Study_PK = A.Qi_HL7StudyID
        WHERE A.PacsID      = 4
          AND A.ToQiSpaceId = 15
          /* Faithful reproduction of the existing Mercy role rule.
             The original is `rolename not in (...)` over a LEFT JOIN,
             so a case with NO role row evaluates UNKNOWN and is
             dropped. EXISTS reproduces that exactly, including the
             drop. That behaviour is measured and recorded in the
             filter notes; it is intentional here, not an oversight. */
          AND EXISTS (
                SELECT 1
                FROM T_CASES_ROLES AR
                JOIN Roles R ON R.RoleID = AR.role_id
                WHERE AR.case_id = A.AssignedCaseId
                  AND R.RoleName NOT IN (
                        'Division - Diagnostic Mammo',
                        'Division - Interventional',
                        'Division - Screening Mammo',
                        'Division - Cardiac MRI',
                        'Division - General')
              )
          /* Window prune, in server-local terms. See WINDOW note below. */
          AND (   (A.CreatedDate  >= @FromLocal AND A.CreatedDate  < @ToLocal)
               OR (A.AssignedDate >= @FromLocal AND A.AssignedDate < @ToLocal)
               OR (A.ReviewedDate >= @FromLocal AND A.ReviewedDate < @ToLocal) )
        /* No modality restriction at Mercy — matches the existing proc. */

        UNION ALL

        /* ---------- TCH (PacsID 1 = "TCH Prod") ---------- */
        SELECT
            siteName        = 'TCH',
            A.AssignedCaseId,
            modality        = ISNULL(H.Modality, '(none)'),
            A.CreatedDate,
            A.AssignedDate,
            A.ReviewedDate
        FROM Qi_AssignedCases A
        LEFT JOIN HL7StudyOLD H
               ON H.HL7Study_PK = A.Qi_HL7StudyID
        WHERE A.PacsID      = 1
          AND A.ToQiSpaceId = 15
          AND H.Modality IN ('CR','CT','DS','DX','MR','NM','PT','RF','RG','US')
          /* TCH's rule keeps roleless cases explicitly (`OR RoleName
             IS NULL`), unlike Mercy. Both halves are reproduced: a
             matching role, or no role row at all. */
          AND (
                EXISTS (
                    SELECT 1
                    FROM T_CASES_ROLES AR
                    LEFT JOIN Roles R ON R.RoleID = AR.role_id
                    WHERE AR.case_id = A.AssignedCaseId
                      AND (R.RoleName IS NULL
                           OR R.RoleName IN (
                                'Administrators','Division - Body',
                                'Division - Cardiac MRI','Division - General',
                                'Division - MSK','Division - Neuro',
                                'Division - Nuclear Medicine',
                                'Division - Uncategorized',
                                'Division - Vascular US','Domain Users',
                                'Emergency Department','Lead Tech',
                                'ordering Physician','QI Committee',
                                'Radiologist','Radiologist Resident',
                                'Referring Physician','Server Operators',
                                'Site Administrator','Technologist'))
                )
                OR NOT EXISTS (
                    SELECT 1 FROM T_CASES_ROLES AR
                    WHERE AR.case_id = A.AssignedCaseId
                )
              )
          AND (   (A.CreatedDate  >= @FromLocal AND A.CreatedDate  < @ToLocal)
               OR (A.AssignedDate >= @FromLocal AND A.AssignedDate < @ToLocal)
               OR (A.ReviewedDate >= @FromLocal AND A.ReviewedDate < @ToLocal) )
    ),
    events AS
    (
        /* Single pass. Each qualifying case contributes up to three
           event rows; the ones outside the window are dropped here.

           This was three UNION ALL legs, one per date column, chosen
           so each would seek. The index survey on 2026-08-27 showed
           only AssignedDate is seekable — CreatedDate is not a key
           column on any index in this database, and we cannot add
           one. Three legs therefore cost a seek plus two scans where
           one pass costs one scan, so the legs were collapsed. */
        SELECT
            p.siteName, p.AssignedCaseId, p.modality,
            v.eventType, v.ts
        FROM pop p
        CROSS APPLY (VALUES
            ('created',  p.CreatedDate),
            ('assigned', p.AssignedDate),
            ('reviewed', p.ReviewedDate)
        ) v(eventType, ts)
        WHERE v.ts >= @FromLocal AND v.ts < @ToLocal
    ),
    utc AS
    (
        /* Interpret the naive column as server-local, then convert
           to UTC. Applied only to rows that already qualified. */
        SELECT
            siteName, AssignedCaseId, modality, eventType,
            tsUtc = CAST(ts AT TIME ZONE @serverZone AT TIME ZONE 'UTC' AS datetime2(0))
        FROM events
    )
    SELECT
        siteName,
        /* Canonical bucket: the UTC instant the hour starts at.
           This is the key downstream. */
        activityHourUtc = DATEADD(hour, DATEDIFF(hour, 0, tsUtc), 0),
        /* Same instant, split out. Convenience for grouping and
           for a Mongo key that reads well — NOT a second source of
           truth, and not to be recombined with a local offset. */
        activityDateUtc = CAST(tsUtc AS date),
        activityHour    = DATEPART(hour, tsUtc),
        modality,
        createdCount  = COUNT(DISTINCT CASE WHEN eventType = 'created'  THEN AssignedCaseId END),
        assignedCount = COUNT(DISTINCT CASE WHEN eventType = 'assigned' THEN AssignedCaseId END),
        reviewedCount = COUNT(DISTINCT CASE WHEN eventType = 'reviewed' THEN AssignedCaseId END)
    FROM utc
    GROUP BY
        siteName,
        DATEADD(hour, DATEDIFF(hour, 0, tsUtc), 0),
        CAST(tsUtc AS date),
        DATEPART(hour, tsUtc),
        modality
    ORDER BY siteName, activityHourUtc, modality;
END
GO

/* ------------------------------------------------------------
   Notes for whoever runs this next.

   TIME ZONE — the contract. Parameters are UTC. Output is UTC.
   activityHourUtc is the canonical value and the downstream key.
   The front end renders Eastern; luxon is already a dependency in
   _netlify/functions/config/mongo.ts:

       DateTime.fromISO(row.activityHourUtc, { zone: 'utc' })
               .setZone('America/New_York')

   Do NOT store or key on a local-time hour. On the November
   fall-back two distinct real hours both label as 1am Eastern, so
   a local key collides and one hour is silently overwritten.

   Do NOT re-derive the hour with JavaScript getHours() either.
   The reason is NOT the one first written here: an earlier draft
   of this note claimed fetchDateData in the workload app is
   already broken that way, "because Netlify functions run UTC".
   That was measured and is wrong. Its fetchDate values are naive
   ISO strings with no offset, and per the ECMAScript Date Time
   String Format a date-TIME form without an offset parses as
   local, so getHours() reads back the stored wall-clock hour in
   every zone — 21 under TZ=UTC, America/New_York and
   America/Los_Angeles alike. That chart is not shifted.

   The rule still stands, for two better reasons. First, it is one
   character from being true: the same call on a value carrying a
   Z, or on a BSON Date, yields 21 / 17 / 14 in those three zones.
   The parse is only stable by accident of the stored format.
   Second, what getHours() faithfully returns there is the SQL
   server's LOCAL hour, presented to every viewer as if it were
   theirs. This proc exists partly to stop that ambiguity
   propagating: emit an explicit UTC bucket and let the front end
   convert once, deliberately.

   Both zones use whole-hour offsets, so a UTC hour bucket maps to
   exactly one Eastern hour bucket and relabelling is lossless. The
   two DST days are the exception: fall-back produces two buckets
   that render as the same Eastern hour, spring-forward leaves a
   gap at 2am. Daily rollups stay correct either way; only the
   hourly chart shows it, twice a year.

   AT TIME ZONE requires SQL Server 2016+. Verify the server really
   is Eastern before trusting @serverZone:
       SELECT SYSDATETIMEOFFSET();

   INDEXES — WE DO NOT OWN THIS DATABASE. Stored procedures can be
   added; indexes cannot. Surveyed 2026-08-27:

     IX_Qi_AssignedCases_ToQiSpaceId
         (ToQiSpaceId, AssignedDate)          -> AssignedDate seeks
     IX_Qi_AssignedCases_CaseStatus_ReviewedDate2
         (CaseStatus, ReviewedDate)           -> only behind CaseStatus
     IX_AssignedCases_CaseStatus_AssignedCaseId
         (CaseStatus, CaseOrigin, AssignedCaseId)
         INCLUDEs AssignedDate, ReviewedDate, CreatedDate,
         ToQiSpaceId, PacsID, Qi_HL7StudyID   -> FULLY COVERING

   CreatedDate is never a key column on any index here, so the
   created events cannot seek and no index can be added to fix it.
   The saving grace is the covering index: the worst case is a scan
   of a narrow covering index, not of the 32-column base table.

   That is why this is one pass rather than three legs. Confirm on
   first run that the plan picks the covering index and does NOT do
   key lookups into the clustered index — lookups over a 4-month
   window would be far worse than the scan.

   COST AND CADENCE. With no seek on CreatedDate, a scan costs the
   same whatever the window: an hourly run is as expensive as a
   daily one, on a production database belonging to someone else.
   Because the loader upserts over a trailing window, polling
   frequency and the hourly data grain are independent — running
   less often with a wider window still yields complete hourly
   buckets. See the task register before changing the schedule.

   JOIN TYPES. A.Qi_HL7StudyID is bigint and H.HL7Study_PK is int,
   so the join carries an implicit convert. Inherited from the
   existing procs; left as-is deliberately rather than changed
   under an unrelated task.

   DUPLICATES. Qi_AssignedCases has OriginalCaseID and DupCaseID.
   Neither is filtered here, matching the existing procs. If de-dup
   is wanted it is a deliberate change, not a silent one.

   MODALITY '(none)'. Cases with no matching study row, or a study
   with a NULL modality, bucket as '(none)' rather than NULL — the
   downstream Mongo upsert keys on modality and the key cannot be
   null. At TCH the modality allow-list already excludes them.
   ------------------------------------------------------------ */

/* Smoke test — last completed UTC hour, both sites.
EXEC dbo.pri_site_daily_ingest;
*/

/* Backfill — 4 months, per the registered decision. UTC bounds.
EXEC dbo.pri_site_daily_ingest '2026-04-27T00:00:00', '2026-08-27T00:00:00';
*/
