/* ============================================================
   dbo.pri_study_audit — WORKING DRAFT
   Reproduces the WI Study Audit report for one accession.
   Status: HL7 Triggers source CONFIRMED; workflow + audit
   sources still being identified. Debug notes at bottom.
   ============================================================ */

-- ------------------------------------------------------------
-- CONFIRMED (7/24/2026): HL7 Triggers source — "gives great results"
-- ------------------------------------------------------------
SELECT *
FROM HL7Triggers T
LEFT JOIN HL7TriggerDetails D ON D.HL7TriggerID = T.HL7TriggerID
WHERE AccessionNumber = '123';


-- ------------------------------------------------------------
-- DISCOVERY: run these to find the workflow + audit tables
-- ------------------------------------------------------------
-- Every table with an accession column:
SELECT TABLE_NAME, COLUMN_NAME
FROM INFORMATION_SCHEMA.COLUMNS
WHERE COLUMN_NAME LIKE '%Accession%'
ORDER BY TABLE_NAME;

-- Candidates by name for the other two report sources:
SELECT name FROM sys.tables
WHERE name LIKE '%Workflow%' OR name LIKE '%Audit%' OR name LIKE '%Case%'
ORDER BY name;

-- Once a candidate is found, inspect its columns:
-- SELECT TOP 5 * FROM <candidate> WHERE ...;
-- Expect: WorkflowTriggers-ish (RuleID, CaseTriggerID, WorkflowRan)
--         AuditLog-ish (rule name / space / case-ID text)
-- NOTE: audit source may key on CaseID, not accession —
--       if so, resolve accession -> CaseID first and join through.


-- ------------------------------------------------------------
-- TARGET SHAPE: the proc the API will call.
-- Result columns must match model/StudyAuditEvent.cs:
--   date, workflowId, event, messageId, didWorkflowRun,
--   details, userName, space, eventName, caseStatus, source
-- ------------------------------------------------------------
/*
CREATE OR ALTER PROCEDURE dbo.pri_study_audit
    @AccessionNumber varchar(50)
AS
BEGIN
    SET NOCOUNT ON;

    -- 1) HL7 Triggers  (CONFIRMED tables; pick/alias final columns)
    SELECT
        T.<datetime_col>                    AS [date],
        CAST(T.<hl7studypk_col> AS varchar(50)) AS [workflowId],
        NULL                                AS [event],
        D.<messageid_col>                   AS [messageId],
        NULL                                AS [didWorkflowRun],
        D.<messagetype_col>                 AS [details],      -- ORM^O01
        T.<feedname_col>                    AS [userName],     -- RIS HL7 Feed / PACS PEN Feed
        NULL AS [space], NULL AS [eventName], NULL AS [caseStatus],
        'HL7 Triggers Table'                AS [source]
    FROM HL7Triggers T
    LEFT JOIN HL7TriggerDetails D ON D.HL7TriggerID = T.HL7TriggerID
    WHERE T.AccessionNumber = @AccessionNumber

    UNION ALL

    -- 2) Workflow Triggers  (TODO: table names)
    -- SELECT ... 'Workflow Triggers Table' AS [source] FROM <?> WHERE ...

    UNION ALL

    -- 3) Audit Log  (TODO: table names; may join via CaseID)
    -- SELECT ... 'Audit Log' AS [source] FROM <?> WHERE ...

    ORDER BY [date] ASC;
END
*/


-- ------------------------------------------------------------
-- DEBUG LOG
-- 7/24/2026  HL7Triggers + HL7TriggerDetails join confirmed working.
--            Workflow + audit sources: pending discovery.
-- ------------------------------------------------------------
