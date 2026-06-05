-- ============================================================
-- outstanding_balance_vs_ar_comparison.sql
--
-- PURPOSE: Compare Query 1's outstanding balance (DPD 0-180)
--          against Query 2's AR result, and surface why they differ.
--
-- KEY STRUCTURAL DIFFERENCES BETWEEN THE TWO QUERIES:
--   1. Q1 joins to credit_card_applications + decisions to get
--      approval_timestamp. This LEFT JOIN can fan out rows if a
--      business has >1 APPROVED application before rn dedup runs.
--      Q2 skips this join entirely.
--
--   2. Q2 filters ending_balance >= 0 (excludes credit balances
--      from overpayments). Q1 does not — those negative-balance
--      accounts pull its total down.
--
--   3. Q2 applies a second ROW_NUMBER (date_rank) per business_id.
--      Since both queries filter to the same single statement_date
--      (last day of prior month), this makes no practical difference
--      in row count — every business has exactly one row on that date.
-- ============================================================

WITH report_date AS (
    -- Single point of truth for the target statement date
    SELECT LAST_DAY(ADD_MONTHS(CURRENT_DATE(), -1)) AS stmt_dt
)

-- ── Base loan tape (Q1 style: includes application join) ─────────────────
,loan_tape_q1 AS (
    SELECT
         a.*
        ,b.business_id
        ,d.created_at                                                        AS approval_timestamp
        ,ROW_NUMBER() OVER (
             PARTITION BY b.business_id, a.statement_date
             ORDER BY a.record_version DESC
         )                                                                   AS rn
    FROM PROD_DB.DATA.CREDIT_CARD_ACCOUNT_LOAN_TAPE_HISTORY a
    LEFT JOIN FIVETRAN_DB.PROD_NOVO_API_PUBLIC.CREDIT_CARD_ACCOUNTS b
        ON a.account_id = b.external_account_id
    LEFT JOIN fivetran_db.prod_novo_api_public.credit_card_applications c
        ON b.business_id = c.business_id
        AND c.status = 'APPROVED'
    LEFT JOIN fivetran_db.prod_novo_api_public.credit_card_application_decisions d
        ON c.id = d.application_id
    WHERE b.business_id NOT IN (
        SELECT business_id FROM FIVETRAN_DB.PROD_NOVO_API_PUBLIC.BUSINESS_GROUP_ASSIGNMENTS
        WHERE business_group_id = '75fe98d2-6549-46a1-aa04-a1c621e21d9e'
    )
)

-- ── Base loan tape (Q2 style: no application join) ───────────────────────
,loan_tape_q2 AS (
    SELECT
         a.*
        ,b.business_id
        ,ROW_NUMBER() OVER (
             PARTITION BY b.business_id, a.statement_date
             ORDER BY a.record_version DESC
         )                                                                   AS rn
    FROM PROD_DB.DATA.CREDIT_CARD_ACCOUNT_LOAN_TAPE_HISTORY a
    LEFT JOIN FIVETRAN_DB.PROD_NOVO_API_PUBLIC.CREDIT_CARD_ACCOUNTS b
        ON a.account_id = b.external_account_id
    WHERE b.business_id NOT IN (
        SELECT business_id FROM FIVETRAN_DB.PROD_NOVO_API_PUBLIC.BUSINESS_GROUP_ASSIGNMENTS
        WHERE business_group_id = '75fe98d2-6549-46a1-aa04-a1c621e21d9e'
    )
)

-- ── Q1: outstanding balance universe (DPD 0–180, no negative balance filter)
,q1_accounts AS (
    SELECT
         business_id
        ,days_past_due
        ,ROUND(ending_balance / 100.0, 2)                                   AS ending_balance
        ,statement_date
    FROM loan_tape_q1
    WHERE rn = 1
      AND statement_date = (SELECT stmt_dt FROM report_date)
      AND days_past_due   BETWEEN 0 AND 180
      AND ending_balance >= 0
)

-- ── Q2: AR universe (DPD 0–180, negative balances excluded)
,q2_accounts AS (
    SELECT
         business_id
        ,days_past_due
        ,ROUND(ending_balance / 100.0, 2)                                   AS ending_balance
        ,statement_date
    FROM loan_tape_q2
    WHERE rn = 1
      AND statement_date = (SELECT stmt_dt FROM report_date)
      AND days_past_due     >= 0
      AND ending_balance    >= 0          -- Q2 explicit filter — key difference vs Q1
      AND days_past_due BETWEEN 0 AND 180
)

-- ============================================================
-- SECTION 1: Top-level comparison
-- ============================================================
SELECT '1. TOP-LINE COMPARISON' AS section, NULL AS detail, NULL AS account_count, NULL AS balance

UNION ALL

SELECT
     'Q1 Outstanding Balance (DPD 0-180)'
    ,NULL
    ,COUNT(DISTINCT business_id)
    ,SUM(ending_balance)
FROM q1_accounts

UNION ALL

SELECT
     'Q2 AR (DPD 0-180)'
    ,NULL
    ,COUNT(DISTINCT business_id)
    ,SUM(ending_balance)
FROM q2_accounts

UNION ALL

SELECT
     'Difference (Q1 minus Q2)'
    ,NULL
    ,COUNT(DISTINCT q1.business_id) - (SELECT COUNT(DISTINCT business_id) FROM q2_accounts)
    ,SUM(q1.ending_balance)         - (SELECT SUM(ending_balance)          FROM q2_accounts)
FROM q1_accounts q1

-- ============================================================
-- SECTION 2: Accounts in Q1 but excluded from Q2
--            Reason: Q2 filters ending_balance >= 0; Q1 does not
-- ============================================================
UNION ALL SELECT '2. ACCOUNTS IN Q1 EXCLUDED BY Q2 (negative ending balance)', NULL, NULL, NULL

UNION ALL

SELECT
     'In Q1, ending_balance < 0 (credit balances — excluded by Q2)'
    ,NULL
    ,COUNT(DISTINCT business_id)
    ,SUM(ending_balance)
FROM q1_accounts
WHERE ending_balance < 0

-- ============================================================
-- SECTION 3: Accounts in Q2 but missing from Q1
--            Reason: application LEFT JOIN in Q1 may suppress rows
--            where credit_card_accounts has no matching business_id
-- ============================================================
UNION ALL SELECT '3. ACCOUNTS IN Q2 NOT FOUND IN Q1 (application join gap)', NULL, NULL, NULL

UNION ALL

SELECT
     'In Q2 but absent from Q1'
    ,NULL
    ,COUNT(DISTINCT q2.business_id)
    ,SUM(q2.ending_balance)
FROM q2_accounts q2
WHERE q2.business_id NOT IN (SELECT business_id FROM q1_accounts)

-- ============================================================
-- SECTION 4: Fan-out risk check
--            If a business has >1 APPROVED application the Q1 join
--            produces extra rows. rn dedup should handle it, but
--            this surfaces how many businesses are at risk.
-- ============================================================
UNION ALL SELECT '4. FAN-OUT RISK: businesses with >1 APPROVED application in Q1 join', NULL, NULL, NULL

UNION ALL

SELECT
     'Businesses with multiple APPROVED applications (fan-out candidates)'
    ,NULL
    ,COUNT(*)
    ,NULL
FROM (
    SELECT b.business_id
    FROM FIVETRAN_DB.PROD_NOVO_API_PUBLIC.CREDIT_CARD_ACCOUNTS b
    JOIN fivetran_db.prod_novo_api_public.credit_card_applications c
        ON b.business_id = c.business_id
        AND c.status = 'APPROVED'
    WHERE b.business_id NOT IN (
        SELECT business_id FROM FIVETRAN_DB.PROD_NOVO_API_PUBLIC.BUSINESS_GROUP_ASSIGNMENTS
        WHERE business_group_id = '75fe98d2-6549-46a1-aa04-a1c621e21d9e'
    )
    GROUP BY b.business_id
    HAVING COUNT(c.id) > 1
) multi_app

ORDER BY section, detail
;
