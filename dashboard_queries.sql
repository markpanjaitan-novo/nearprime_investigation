-- ============================================================
-- dashboard_queries.sql
-- Credit Dashboard — All SQL Queries
-- Generated: 2026-06-01
-- ============================================================


-- ============================================================
-- CREDIT CARD TAB  (sections above "Reference")
-- ============================================================


-- ------------------------------------------------------------
-- 1. Monthly Approved Applications (2026)
-- ------------------------------------------------------------
SELECT
    TO_CHAR(created_at, 'YYYY-MM') AS year_month,
    COUNT(*) AS total
FROM fivetran_db.prod_novo_api_public.credit_card_applications
WHERE business_id NOT IN (
    SELECT business_id
    FROM FIVETRAN_DB.PROD_NOVO_API_PUBLIC.BUSINESS_GROUP_ASSIGNMENTS
    WHERE business_group_id = '75fe98d2-6549-46a1-aa04-a1c621e21d9e'
)
AND TO_CHAR(created_at, 'YYYY-MM-DD') > '2026-01-01'
AND status = 'APPROVED'
GROUP BY TO_CHAR(created_at, 'YYYY-MM')
ORDER BY TO_CHAR(created_at, 'YYYY-MM')
;


-- ------------------------------------------------------------
-- 2. FICO Breakdown — Approved Apps (May 2026 Campaign)
--    Shows total invited, total approved, avg limit by FICO bin
--    Invitation filter: created_at >= 2026-05-28
-- ------------------------------------------------------------
WITH invitations AS (
    SELECT DISTINCT business_id, FICO_SCORE
    FROM fivetran_db.prod_novo_api_public.credit_card_invitations
    WHERE created_at >= '2026-05-28'
)
SELECT
    CASE
        WHEN i.FICO_SCORE >= 580 AND i.FICO_SCORE < 620 THEN '[580-620]'
        WHEN i.FICO_SCORE >= 620 AND i.FICO_SCORE < 680 THEN '[620-680]'
        WHEN i.FICO_SCORE >= 680 AND i.FICO_SCORE < 720 THEN '[680-720]'
        WHEN i.FICO_SCORE >= 720 AND i.FICO_SCORE < 780 THEN '[720-780]'
        WHEN i.FICO_SCORE >= 780 THEN '[780+]'
        ELSE 'Other/Missing'
    END AS fico_bin,
    COUNT(DISTINCT i.business_id) AS total_invited,
    COUNT(DISTINCT CASE WHEN a.status = 'APPROVED' THEN a.business_id END) AS approved_apps,
    AVG(CASE WHEN a.status = 'APPROVED' THEN a.credit_limit / 100 END) AS avg_limit
FROM invitations i
LEFT JOIN fivetran_db.prod_novo_api_public.credit_card_applications a
    ON i.business_id = a.business_id
GROUP BY 1
ORDER BY 1
;


-- ------------------------------------------------------------
-- 3. Campaign Comparison — Jan vs Mar/Apr/May Daily Approved
--    Four sub-queries combined in the backend; run separately
-- ------------------------------------------------------------

-- 3a. Jan Campaign (blue line, Day 1 = 2026-01-28)
SELECT
    TO_CHAR(created_at, 'YYYY-MM-DD') AS application_date,
    DAYNAME(created_at) AS day_of_week,
    COUNT(*) AS approved_count
FROM fivetran_db.prod_novo_api_public.credit_card_applications
WHERE business_id NOT IN (
    SELECT business_id FROM FIVETRAN_DB.PROD_NOVO_API_PUBLIC.BUSINESS_GROUP_ASSIGNMENTS
    WHERE business_group_id = '75fe98d2-6549-46a1-aa04-a1c621e21d9e'
)
AND created_at >= '2026-01-28'
AND created_at < '2026-03-01'
AND status = 'APPROVED'
GROUP BY 1, 2
ORDER BY 1 ASC
;

-- 3b. Mar Campaign (red line) + Apr Campaign (purple line)
--     Invitation filter: 2026-03-20 to 2026-04-05, earliest invite per business
--     Day 1 = 2026-03-26; apps capped at 2026-04-27
WITH most_recent_invite AS (
    SELECT *,
        ROW_NUMBER() OVER (PARTITION BY business_id ORDER BY created_at ASC) AS rn
    FROM fivetran_db.prod_novo_api_public.credit_card_invitations
    WHERE created_at >= '2026-03-20' AND created_at <= '2026-04-05'
)
SELECT
    TO_CHAR(a.created_at, 'YYYY-MM-DD') AS application_date,
    DAYNAME(a.created_at) AS day_of_week,
    CASE
        WHEN TO_CHAR(b.created_at, 'YYYY-MM') = '2026-03' THEN 'MAR'
        WHEN TO_CHAR(b.created_at, 'YYYY-MM') = '2026-04' THEN 'APR'
        ELSE 'OTHER'
    END AS campaign,
    COUNT(*) AS approved_count
FROM fivetran_db.prod_novo_api_public.credit_card_applications AS a
LEFT JOIN (SELECT * FROM most_recent_invite WHERE rn = 1) AS b
    ON a.business_id = b.business_id
WHERE a.business_id NOT IN (
    SELECT business_id FROM FIVETRAN_DB.PROD_NOVO_API_PUBLIC.BUSINESS_GROUP_ASSIGNMENTS
    WHERE business_group_id = '75fe98d2-6549-46a1-aa04-a1c621e21d9e'
)
AND TO_CHAR(a.created_at, 'YYYY-MM-DD') > '2026-03-25'
AND TO_CHAR(a.created_at, 'YYYY-MM-DD') <= '2026-04-27'
AND a.status = 'APPROVED'
GROUP BY 1, 2, 3
ORDER BY 1 ASC
;

-- 3c. Apr Camp (green line, Day 1 = 2026-04-27)
--     Invitation filter: month = 2026-04, most recent invite per business
WITH most_recent_invite AS (
    SELECT *,
        ROW_NUMBER() OVER (PARTITION BY business_id ORDER BY created_at DESC) AS rn
    FROM fivetran_db.prod_novo_api_public.credit_card_invitations
    WHERE TO_CHAR(created_at, 'YYYY-MM') = '2026-04'
)
SELECT
    TO_CHAR(a.created_at, 'YYYY-MM-DD') AS application_date,
    DAYNAME(a.created_at) AS day_of_week,
    CASE
        WHEN b.created_at >= '2026-04-25' AND b.created_at <= '2026-05-27' THEN 'APR Camp'
        ELSE 'OTHER'
    END AS campaign,
    COUNT(*) AS approved_count
FROM fivetran_db.prod_novo_api_public.credit_card_applications AS a
LEFT JOIN (SELECT * FROM most_recent_invite WHERE rn = 1) AS b
    ON a.business_id = b.business_id
WHERE a.business_id NOT IN (
    SELECT business_id FROM FIVETRAN_DB.PROD_NOVO_API_PUBLIC.BUSINESS_GROUP_ASSIGNMENTS
    WHERE business_group_id = '75fe98d2-6549-46a1-aa04-a1c621e21d9e'
)
AND TO_CHAR(a.created_at, 'YYYY-MM-DD') >= '2026-04-27'
AND a.status = 'APPROVED'
GROUP BY 1, 2, 3
ORDER BY 1 ASC
;

-- 3d. May Camp (orange line, Day 1 = 2026-05-28)
--     Invitation filter: month = 2026-05, most recent invite per business
WITH most_recent_invite AS (
    SELECT *,
        ROW_NUMBER() OVER (PARTITION BY business_id ORDER BY created_at DESC) AS rn
    FROM fivetran_db.prod_novo_api_public.credit_card_invitations
    WHERE TO_CHAR(created_at, 'YYYY-MM') = '2026-05'
)
SELECT
    TO_CHAR(a.created_at, 'YYYY-MM-DD') AS application_date,
    DAYNAME(a.created_at) AS day_of_week,
    CASE
        WHEN b.created_at >= '2026-05-28' THEN 'MAY Camp'
        ELSE 'OTHER'
    END AS campaign,
    COUNT(*) AS approved_count
FROM fivetran_db.prod_novo_api_public.credit_card_applications AS a
LEFT JOIN (SELECT * FROM most_recent_invite WHERE rn = 1) AS b
    ON a.business_id = b.business_id
WHERE a.business_id NOT IN (
    SELECT business_id FROM FIVETRAN_DB.PROD_NOVO_API_PUBLIC.BUSINESS_GROUP_ASSIGNMENTS
    WHERE business_group_id = '75fe98d2-6549-46a1-aa04-a1c621e21d9e'
)
AND TO_CHAR(a.created_at, 'YYYY-MM-DD') >= '2026-05-28'
AND a.status = 'APPROVED'
GROUP BY 1, 2, 3
ORDER BY 1 ASC
;


-- ------------------------------------------------------------
-- 4. Current Balance at Bucket Level
--    Snapshot: 2 days ago. One row total — ending_balance by DPD bucket.
--    Total AR computed in frontend as sum of all buckets.
-- ------------------------------------------------------------
WITH loan_tape_updated AS (
    SELECT a.*,
        b.business_id,
        ROW_NUMBER() OVER (PARTITION BY b.business_id, a.statement_date ORDER BY a.record_version DESC) AS rn
    FROM PROD_DB.DATA.CREDIT_CARD_ACCOUNT_LOAN_TAPE_HISTORY a
    LEFT JOIN FIVETRAN_DB.PROD_NOVO_API_PUBLIC.CREDIT_CARD_ACCOUNTS b
        ON a.account_id = b.external_account_id
    WHERE b.business_id NOT IN (
        SELECT business_id FROM FIVETRAN_DB.PROD_NOVO_API_PUBLIC.BUSINESS_GROUP_ASSIGNMENTS
        WHERE business_group_id = '75fe98d2-6549-46a1-aa04-a1c621e21d9e'
    )
),
RankedStatements AS (
    SELECT
        business_id,
        days_past_due,
        ending_balance / 100 AS ending_balance_vf,
        statement_date,
        ROW_NUMBER() OVER (PARTITION BY business_id ORDER BY statement_date DESC) AS date_rank
    FROM loan_tape_updated
    WHERE days_past_due >= 0
      AND (ending_balance / 100) > 0
      AND DATEDIFF(day, statement_date, CURRENT_DATE) = 2
)
SELECT
    SUM(CASE WHEN days_past_due = 0                              THEN ending_balance_vf ELSE 0 END) AS ending_balance_current,
    SUM(CASE WHEN days_past_due BETWEEN 1   AND 29              THEN ending_balance_vf ELSE 0 END) AS ending_balance_d1_29,
    SUM(CASE WHEN days_past_due BETWEEN 30  AND 59              THEN ending_balance_vf ELSE 0 END) AS ending_balance_d30_59,
    SUM(CASE WHEN days_past_due BETWEEN 60  AND 89              THEN ending_balance_vf ELSE 0 END) AS ending_balance_d60_89,
    SUM(CASE WHEN days_past_due BETWEEN 90  AND 119             THEN ending_balance_vf ELSE 0 END) AS ending_balance_d90_119,
    SUM(CASE WHEN days_past_due BETWEEN 120 AND 149             THEN ending_balance_vf ELSE 0 END) AS ending_balance_d120_149,
    SUM(CASE WHEN days_past_due BETWEEN 150 AND 180             THEN ending_balance_vf ELSE 0 END) AS ending_balance_d150_180
FROM RankedStatements
WHERE date_rank = 1
;


-- ------------------------------------------------------------
-- 5. Weekly Portfolio View + DQ Rate Trend Chart
--    Weekly ending_balance by DPD bucket + pct_D30_59 / pct_D30_plus
-- ------------------------------------------------------------
WITH RECURSIVE WeekEnds AS (
    SELECT '2026-01-04'::DATE AS week_end_date
    UNION ALL
    SELECT DATEADD(day, 7, week_end_date)
    FROM WeekEnds
    WHERE DATEADD(day, 7, week_end_date) <= CURRENT_DATE
),
loan_tape_deduped AS (
    SELECT * FROM (
        SELECT a.*,
               b.business_id,
               ROW_NUMBER() OVER (
                   PARTITION BY b.business_id, a.statement_date
                   ORDER BY a.record_version DESC
               ) AS rn
        FROM PROD_DB.DATA.CREDIT_CARD_ACCOUNT_LOAN_TAPE_HISTORY a
        LEFT JOIN FIVETRAN_DB.PROD_NOVO_API_PUBLIC.CREDIT_CARD_ACCOUNTS b
            ON a.account_id = b.external_account_id
        WHERE b.business_id NOT IN (
            SELECT business_id FROM FIVETRAN_DB.PROD_NOVO_API_PUBLIC.BUSINESS_GROUP_ASSIGNMENTS
            WHERE business_group_id = '75fe98d2-6549-46a1-aa04-a1c621e21d9e'
        )
    )
    WHERE rn = 1
),
RankedStatements AS (
    SELECT
        w.week_end_date,
        lt.business_id,
        lt.days_past_due,
        lt.ending_balance / 100 AS ending_balance_vf,
        lt.statement_date,
        ROW_NUMBER() OVER (
            PARTITION BY w.week_end_date, lt.business_id
            ORDER BY lt.statement_date DESC
        ) AS date_rank
    FROM WeekEnds w
    INNER JOIN loan_tape_deduped lt
        ON lt.statement_date <= w.week_end_date
    WHERE lt.days_past_due >= 0
),
WeeklyRollup AS (
    SELECT
        week_end_date,
        SUM(CASE WHEN days_past_due BETWEEN 0 AND 180   THEN ending_balance_vf ELSE 0 END) AS AR,
        SUM(CASE WHEN days_past_due = 0                 THEN ending_balance_vf ELSE 0 END) AS ending_balance_current,
        SUM(CASE WHEN days_past_due BETWEEN 1 AND 29    THEN ending_balance_vf ELSE 0 END) AS ending_balance_d1_29,
        SUM(CASE WHEN days_past_due BETWEEN 30 AND 59   THEN ending_balance_vf ELSE 0 END) AS ending_balance_d30_59,
        SUM(CASE WHEN days_past_due BETWEEN 60 AND 89   THEN ending_balance_vf ELSE 0 END) AS ending_balance_d60_89,
        SUM(CASE WHEN days_past_due BETWEEN 90 AND 119  THEN ending_balance_vf ELSE 0 END) AS ending_balance_d90_119,
        SUM(CASE WHEN days_past_due BETWEEN 120 AND 149 THEN ending_balance_vf ELSE 0 END) AS ending_balance_d120_149,
        SUM(CASE WHEN days_past_due BETWEEN 150 AND 180 THEN ending_balance_vf ELSE 0 END) AS ending_balance_d150_180
    FROM RankedStatements
    WHERE date_rank = 1
    GROUP BY week_end_date
)
SELECT
    week_end_date,
    AR,
    ending_balance_current,
    ending_balance_d1_29,
    ending_balance_d30_59,
    ending_balance_d60_89,
    ending_balance_d90_119,
    ending_balance_d120_149,
    ending_balance_d150_180,
    ROUND(COALESCE(ending_balance_d30_59 / NULLIF(AR, 0), 0) * 100, 2)                                         AS pct_D30_59,
    ROUND(COALESCE((AR - ending_balance_current - ending_balance_d1_29) / NULLIF(AR, 0), 0) * 100, 2)          AS pct_D30_plus
FROM WeeklyRollup
ORDER BY week_end_date DESC
;


-- ------------------------------------------------------------
-- 6. Credit Card Monthly Revenue Summary
--    Interchange + Interest + Fees + Rewards + Chargeoffs by booking cohort month
-- ------------------------------------------------------------
WITH latest_invite AS (
    SELECT business_id, MAX(created_at) AS last_invite_at
    FROM FIVETRAN_DB.PROD_NOVO_API_PUBLIC.CREDIT_CARD_INVITATIONS
    GROUP BY 1
),
campaigned AS (
    SELECT
        business_id,
        CASE
            WHEN TO_CHAR(last_invite_at, 'YYYY-MM') BETWEEN '2024-11' AND '2025-07' THEN 'FT'
            WHEN TO_CHAR(last_invite_at, 'YYYY-MM') BETWEEN '2025-11' AND '2026-01' THEN 'CART'
            WHEN TO_CHAR(last_invite_at, 'YYYY-MM') >= '2026-03'                    THEN 'NAM'
            ELSE 'Other'
        END AS campaign
    FROM latest_invite
),
loan_tape_updated AS (
    SELECT
        a.*, b.business_id, b.id AS cc_account_id, b.status, b.updated_at,
        ROW_NUMBER() OVER (PARTITION BY b.business_id, a.statement_date ORDER BY a.record_version DESC) AS rn,
        CAST(NULL AS VARCHAR) AS risk_bucket,
        COALESCE(c.campaign, 'Other') AS campaign
    FROM PROD_DB.DATA.CREDIT_CARD_ACCOUNT_LOAN_TAPE_HISTORY a
    LEFT JOIN FIVETRAN_DB.PROD_NOVO_API_PUBLIC.CREDIT_CARD_ACCOUNTS b ON a.account_id = b.external_account_id
    LEFT JOIN campaigned c ON c.business_id = b.business_id
    WHERE b.business_id NOT IN (
        SELECT business_id FROM FIVETRAN_DB.PROD_NOVO_API_PUBLIC.BUSINESS_GROUP_ASSIGNMENTS
        WHERE business_group_id = '75fe98d2-6549-46a1-aa04-a1c621e21d9e'
    )
    AND a.billing_period_number >= 1
),
booking_date AS (
    SELECT
         ca.business_id
        ,CAST(NULL AS VARCHAR)         AS risk_bucket
        ,COALESCE(c.campaign, 'Other') AS campaign
        ,MIN(app.created_at)           AS created_at
    FROM FIVETRAN_DB.PROD_NOVO_API_PUBLIC.CREDIT_CARD_ACCOUNTS ca
    JOIN FIVETRAN_DB.PROD_NOVO_API_PUBLIC.CREDIT_CARD_APPLICATIONS app
        ON  app.business_id = ca.business_id
        AND app.status = 'APPROVED'
    LEFT JOIN campaigned c ON c.business_id = ca.business_id
    WHERE COALESCE(ca._fivetran_deleted, FALSE) = FALSE
      AND ca.business_id NOT IN (
          SELECT business_id FROM FIVETRAN_DB.PROD_NOVO_API_PUBLIC.BUSINESS_GROUP_ASSIGNMENTS
          WHERE business_group_id = '75fe98d2-6549-46a1-aa04-a1c621e21d9e'
      )
    GROUP BY 1, 2, 3
),
loan_tape_statement_join AS (
    SELECT a.*, b.purchases AS pvol, c.created_at, b.start_date, b.end_date
    FROM (SELECT * FROM loan_tape_updated WHERE rn = 1) a
    RIGHT JOIN (
        SELECT * FROM FIVETRAN_DB.PROD_NOVO_API_PUBLIC.CREDIT_CARD_STATEMENTS
        WHERE business_id NOT IN (
            SELECT business_id FROM FIVETRAN_DB.PROD_NOVO_API_PUBLIC.BUSINESS_GROUP_ASSIGNMENTS
            WHERE business_group_id = '75fe98d2-6549-46a1-aa04-a1c621e21d9e'
        )
    ) b ON a.business_id = b.business_id
        AND TO_CHAR(a.statement_date, 'YYYY-MM-DD') = TO_CHAR(b.created_at, 'YYYY-MM-DD')
    LEFT JOIN booking_date c ON a.business_id = c.business_id
),
interchange AS (
    SELECT a.business_id, a.statement_date,
        ROUND(SUM(b.interchange_gross_amount * -1 / 100), 2) AS interchange_amount
    FROM loan_tape_statement_join a
    LEFT JOIN FIVETRAN_DB.PROD_NOVO_API_PUBLIC.CREDIT_CARD_NOVO_SETTLEMENT_REPORT_ITEMS b
        ON a.cc_account_id = b.credit_card_account_id
        AND TO_CHAR(b.created_at, 'YYYY-MM-DD') BETWEEN a.start_date AND a.end_date
    GROUP BY 1, 2
),
interest_and_fees AS (
    SELECT a.business_id, a.statement_date,
        ROUND(SUM(b.payment_allocated_interest / 100), 2) AS interest_collected,
        ROUND(SUM(b.payment_allocated_fees     / 100), 2) AS fees_collected
    FROM loan_tape_statement_join a
    LEFT JOIN (SELECT * FROM loan_tape_updated WHERE rn = 1) b
        ON a.business_id = b.business_id
        AND b.statement_date BETWEEN a.start_date AND a.end_date
    GROUP BY 1, 2
),
reward_redemption AS (
    SELECT a.business_id, a.statement_date,
        COALESCE(ROUND(SUM(rewards / 100), 2), 0) AS reward_accrued
    FROM loan_tape_statement_join a
    LEFT JOIN FIVETRAN_DB.PROD_NOVO_API_PUBLIC.CREDIT_CARD_TRANSACTION_REWARD_ITEMS b
        ON a.cc_account_id = b.credit_card_account_id
        AND TO_CHAR(b.created_at, 'YYYY-MM-DD') BETWEEN a.start_date AND a.end_date
    GROUP BY 1, 2
),
purchase_fraud AS (
    SELECT a.business_id, a.statement_date,
        ROUND(SUM(b.amount / 100), 2) AS purchase_fraud_amount
    FROM loan_tape_statement_join a
    LEFT JOIN FIVETRAN_DB.PROD_NOVO_API_PUBLIC.CREDIT_CARD_TRANSACTION_DISPUTES b
        ON a.business_id = b.business_id
        AND TO_CHAR(b.created_at, 'YYYY-MM-DD') BETWEEN a.start_date AND a.end_date
    WHERE b.status = 'accepted'
    GROUP BY 1, 2
),
final AS (
    SELECT
        TO_CHAR(a.created_at, 'YYYY-MM') AS booking_month,
        CASE WHEN a.billing_period_number - 1 = 0 THEN a.billing_period_number
             ELSE a.billing_period_number - 1 END AS booking_stmt_no,
        a.risk_bucket,
        a.campaign,
        SUM(b.interchange_amount)    AS interchange_amount,
        SUM(c.interest_collected)    AS interest_collected,
        SUM(c.fees_collected)        AS fees_collected,
        SUM(d.reward_accrued)        AS reward_accrued,
        SUM(e.purchase_fraud_amount) AS purchase_fraud_amount,
        ROUND(SUM(CASE WHEN a.days_past_due BETWEEN 180 AND 210
                       THEN (a.next_due_principal + a.past_statements_principal
                           + a.due_principal + a.past_due_principal) END) / 100, 2) AS co_amount
    FROM loan_tape_statement_join a
    LEFT JOIN interchange       b ON a.business_id = b.business_id AND a.statement_date = b.statement_date
    LEFT JOIN interest_and_fees c ON a.business_id = c.business_id AND a.statement_date = c.statement_date
    LEFT JOIN reward_redemption d ON a.business_id = d.business_id AND a.statement_date = d.statement_date
    LEFT JOIN purchase_fraud    e ON a.business_id = e.business_id AND a.statement_date = e.statement_date
    WHERE a.business_id NOT IN (
        SELECT business_id FROM FIVETRAN_DB.PROD_NOVO_API_PUBLIC.BUSINESS_GROUP_ASSIGNMENTS
        WHERE business_group_id = '75fe98d2-6549-46a1-aa04-a1c621e21d9e'
    )
    AND a.billing_period_number != 0
    AND TO_CHAR(a.created_at, 'YYYY-MM') < TO_CHAR(DATEADD(month, -1, CURRENT_DATE), 'YYYY-MM')
    AND (CASE WHEN a.billing_period_number - 1 = 0 THEN a.billing_period_number
              ELSE a.billing_period_number - 1 END) < DATEDIFF(month, a.created_at, CURRENT_DATE)
    GROUP BY 1, 2, 3, 4
)
SELECT
    TO_CHAR(DATEADD(month, f.booking_stmt_no, TO_DATE(f.booking_month || '-01', 'YYYY-MM-DD')), 'YYYY-MM') AS report_month,
    SUM(COALESCE(f.interchange_amount, 0))                                                                  AS interchange_amount,
    SUM(COALESCE(f.interest_collected, 0))                                                                  AS interest_collected,
    SUM(COALESCE(f.fees_collected,     0))                                                                  AS fees_collected,
    SUM(COALESCE(f.interchange_amount, 0) + COALESCE(f.interest_collected, 0) + COALESCE(f.fees_collected, 0)) AS total_revenue,
    SUM(COALESCE(f.co_amount,             0))                                                               AS co_amount,
    SUM(COALESCE(f.reward_accrued,        0))                                                               AS reward_accrued,
    SUM(COALESCE(f.purchase_fraud_amount, 0))                                                               AS purchase_fraud_amount,
    SUM(COALESCE(f.co_amount, 0) + COALESCE(f.reward_accrued, 0) + COALESCE(f.purchase_fraud_amount, 0))   AS total_cost,
    SUM(COALESCE(f.interchange_amount, 0) + COALESCE(f.interest_collected, 0) + COALESCE(f.fees_collected, 0)
      - COALESCE(f.co_amount, 0) - COALESCE(f.reward_accrued, 0) - COALESCE(f.purchase_fraud_amount, 0))   AS nibt
FROM final f
WHERE f.booking_month IS NOT NULL
  AND f.booking_stmt_no IS NOT NULL
GROUP BY 1
HAVING report_month >= '2025-11'
ORDER BY 1 DESC
;


-- ------------------------------------------------------------
-- 7. High Balance DQ (DPD 1-29, Balance >= $10K)
-- ------------------------------------------------------------
WITH loan_tape_updated AS (
    SELECT a.*,
        b.business_id,
        ROW_NUMBER() OVER (PARTITION BY b.business_id, a.statement_date ORDER BY a.record_version DESC) AS rn
    FROM PROD_DB.DATA.CREDIT_CARD_ACCOUNT_LOAN_TAPE_HISTORY a
    LEFT JOIN FIVETRAN_DB.PROD_NOVO_API_PUBLIC.CREDIT_CARD_ACCOUNTS b
        ON a.account_id = b.external_account_id
    WHERE b.business_id NOT IN (
        SELECT business_id FROM FIVETRAN_DB.PROD_NOVO_API_PUBLIC.BUSINESS_GROUP_ASSIGNMENTS
        WHERE business_group_id = '75fe98d2-6549-46a1-aa04-a1c621e21d9e'
    )
),
RankedStatements AS (
    SELECT
        business_id, days_past_due, account_status, account_substatus,
        ending_balance / 100 AS ending_balance_vf,
        (next_due_principal+past_statements_principal+due_principal+past_due_principal)/100 AS principal_balance_vf,
        credit_limit / 100 AS credit_limit_vf,
        statement_date,
        ROW_NUMBER() OVER (PARTITION BY business_id ORDER BY statement_date DESC) AS date_rank
    FROM loan_tape_updated
    WHERE days_past_due BETWEEN 1 AND 29
      AND (ending_balance / 100) >= 10000
      AND DATEDIFF(day, statement_date, CURRENT_DATE) = 2
),
most_recent_invite AS (
    SELECT *, ROW_NUMBER() OVER (PARTITION BY business_id ORDER BY created_at DESC) AS rn
    FROM fivetran_db.prod_novo_api_public.credit_card_invitations
),
loan_tape_updated_v2 AS (
    SELECT a.*, b.business_id AS biz_id, b.id AS cc_account_id,
        ROW_NUMBER() OVER (PARTITION BY b.business_id, a.statement_date ORDER BY a.record_version DESC) AS rn2,
        c.fico_score
    FROM PROD_DB.DATA.CREDIT_CARD_ACCOUNT_LOAN_TAPE_HISTORY a
    LEFT JOIN FIVETRAN_DB.PROD_NOVO_API_PUBLIC.CREDIT_CARD_ACCOUNTS b ON a.account_id = b.external_account_id
    LEFT JOIN (SELECT * FROM most_recent_invite WHERE rn = 1) c ON b.business_id = c.business_id
    WHERE b.business_id NOT IN (
        SELECT business_id FROM FIVETRAN_DB.PROD_NOVO_API_PUBLIC.BUSINESS_GROUP_ASSIGNMENTS
        WHERE business_group_id = '75fe98d2-6549-46a1-aa04-a1c621e21d9e'
    )
    AND a.billing_period_number >= 1
),
first_date AS (
    SELECT biz_id AS business_id, statement_date,
        ROW_NUMBER() OVER (PARTITION BY biz_id ORDER BY statement_date ASC) AS rn
    FROM loan_tape_updated_v2
)
SELECT
    a.business_id, days_past_due, account_status, account_substatus,
    ending_balance_vf, credit_limit_vf,
    a.statement_date AS current_datev,
    b.fico_risk_v8 AS fico_as_of_now,
    TO_CHAR(c.statement_date, 'YYYY-MM') AS vintage_month
FROM RankedStatements a
LEFT JOIN (
    SELECT * FROM prod_db.data.experian_credit_report
    WHERE created_at >= '2026-03-01' AND created_at <= '2026-03-28'
) b ON a.business_id = b.business_id
LEFT JOIN (SELECT business_id, statement_date FROM first_date WHERE rn = 1) c ON a.business_id = c.business_id
WHERE date_rank = 1
ORDER BY days_past_due ASC, ending_balance_vf DESC
;


-- ------------------------------------------------------------
-- 8. High FICO DQ (DPD > 0, FICO > 700)
-- ------------------------------------------------------------
WITH loan_tape_updated AS (
    SELECT a.*,
        b.business_id,
        ROW_NUMBER() OVER (PARTITION BY b.business_id, a.statement_date ORDER BY a.record_version DESC) AS rn
    FROM PROD_DB.DATA.CREDIT_CARD_ACCOUNT_LOAN_TAPE_HISTORY a
    LEFT JOIN FIVETRAN_DB.PROD_NOVO_API_PUBLIC.CREDIT_CARD_ACCOUNTS b
        ON a.account_id = b.external_account_id
    WHERE b.business_id NOT IN (
        SELECT business_id FROM FIVETRAN_DB.PROD_NOVO_API_PUBLIC.BUSINESS_GROUP_ASSIGNMENTS
        WHERE business_group_id = '75fe98d2-6549-46a1-aa04-a1c621e21d9e'
    )
),
RankedStatements AS (
    SELECT
        business_id, days_past_due, account_status, account_substatus,
        ending_balance / 100 AS ending_balance_vf,
        (next_due_principal+past_statements_principal+due_principal+past_due_principal)/100 AS principal_balance_vf,
        credit_limit / 100 AS credit_limit_vf,
        statement_date,
        ROW_NUMBER() OVER (PARTITION BY business_id ORDER BY statement_date DESC) AS date_rank
    FROM loan_tape_updated
    WHERE days_past_due > 0
      AND (ending_balance / 100) > 0
      AND DATEDIFF(day, statement_date, CURRENT_DATE) = 2
),
most_recent_invite AS (
    SELECT *, ROW_NUMBER() OVER (PARTITION BY business_id ORDER BY created_at DESC) AS rn
    FROM fivetran_db.prod_novo_api_public.credit_card_invitations
),
loan_tape_updated_v2 AS (
    SELECT a.*, b.business_id AS biz_id, b.id AS cc_account_id,
        ROW_NUMBER() OVER (PARTITION BY b.business_id, a.statement_date ORDER BY a.record_version DESC) AS rn2,
        c.fico_score
    FROM PROD_DB.DATA.CREDIT_CARD_ACCOUNT_LOAN_TAPE_HISTORY a
    LEFT JOIN FIVETRAN_DB.PROD_NOVO_API_PUBLIC.CREDIT_CARD_ACCOUNTS b ON a.account_id = b.external_account_id
    LEFT JOIN (SELECT * FROM most_recent_invite WHERE rn = 1) c ON b.business_id = c.business_id
    WHERE b.business_id NOT IN (
        SELECT business_id FROM FIVETRAN_DB.PROD_NOVO_API_PUBLIC.BUSINESS_GROUP_ASSIGNMENTS
        WHERE business_group_id = '75fe98d2-6549-46a1-aa04-a1c621e21d9e'
    )
    AND a.billing_period_number >= 1
),
first_date AS (
    SELECT biz_id AS business_id, statement_date,
        ROW_NUMBER() OVER (PARTITION BY biz_id ORDER BY statement_date ASC) AS rn
    FROM loan_tape_updated_v2
)
SELECT
    a.business_id, days_past_due, account_status, account_substatus,
    ending_balance_vf, credit_limit_vf,
    a.statement_date AS current_datev,
    b.fico_risk_v8 AS fico_as_of_now,
    TO_CHAR(c.statement_date, 'YYYY-MM') AS vintage_month
FROM RankedStatements a
LEFT JOIN (
    SELECT * FROM prod_db.data.experian_credit_report
    WHERE created_at >= '2026-03-01' AND created_at <= '2026-03-28'
) b ON a.business_id = b.business_id
LEFT JOIN (SELECT business_id, statement_date FROM first_date WHERE rn = 1) c ON a.business_id = c.business_id
WHERE date_rank = 1 AND b.fico_risk_v8 > 700
ORDER BY days_past_due DESC
;


-- ============================================================
-- MCA TAB  (all sections)
-- ============================================================


-- ------------------------------------------------------------
-- 9. MCA 2026 Total Approved Accounts (bar chart)
-- ------------------------------------------------------------
SELECT
    TO_CHAR(created_at, 'YYYY-MM')  AS invite_month,
    COUNT(business_id)               AS total_count
FROM fivetran_db.prod_novo_api_public.lending_businesses
WHERE TO_CHAR(created_at, 'YYYY-MM-DD') >= '2026-01-01'
GROUP BY TO_CHAR(created_at, 'YYYY-MM')
ORDER BY TO_CHAR(created_at, 'YYYY-MM')
;


-- ------------------------------------------------------------
-- 10. MCA Monthly Approved Accounts (May 2026)
--     Bar chart: total invited vs total approved by risk_bin
--     Table: total invited, total approved, conversion rate,
--            avg offer limit, avg FICO (invite)
-- ------------------------------------------------------------

-- 10a. Invitation side
WITH MCA_invite AS (
    SELECT business_id, created_at
    FROM fivetran_db.prod_novo_api_public.lending_invitations
    WHERE TO_CHAR(created_at, 'YYYY-MM') >= '2026-05'
),
invite_score AS (
    SELECT a.business_id, b.risk_bin, b.fico_score
    FROM MCA_invite a
    LEFT JOIN prod_db.models.mca_uw_eligibility_base b
        ON a.business_id = b.business_id
        AND TO_CHAR(a.created_at, 'YYYY-MM') = TO_CHAR(b.run_date, 'YYYY-MM')
)
SELECT risk_bin, COUNT(business_id) AS total_invited, AVG(fico_score) AS avg_fico_invite
FROM invite_score
GROUP BY risk_bin
ORDER BY risk_bin
;

-- 10b. Approved side
WITH MCA_approved AS (
    SELECT business_id, created_at, credit_limit / 100 AS offer_limit
    FROM fivetran_db.prod_novo_api_public.lending_businesses
    WHERE TO_CHAR(created_at, 'YYYY-MM-DD') >= '2026-05-29'
),
approved_profile AS (
    SELECT a.business_id, a.offer_limit, b.risk_bin, b.fico_score
    FROM MCA_approved a
    LEFT JOIN (
        SELECT * FROM prod_db.models.mca_uw_eligibility_base
        WHERE TO_CHAR(run_date, 'YYYY-MM') = '2026-05'
    ) b ON a.business_id = b.business_id
)
SELECT risk_bin, COUNT(business_id) AS total_approved, AVG(offer_limit) AS avg_offer_limit
FROM approved_profile
GROUP BY risk_bin
ORDER BY risk_bin
;

-- 10c. Combined (used in dashboard)
WITH MCA_invite AS (
    SELECT business_id, created_at
    FROM fivetran_db.prod_novo_api_public.lending_invitations
    WHERE TO_CHAR(created_at, 'YYYY-MM') >= '2026-05'
),
invite_score AS (
    SELECT a.business_id, b.risk_bin, b.fico_score
    FROM MCA_invite a
    LEFT JOIN prod_db.models.mca_uw_eligibility_base b
        ON a.business_id = b.business_id
        AND TO_CHAR(a.created_at, 'YYYY-MM') = TO_CHAR(b.run_date, 'YYYY-MM')
),
invite_by_bin AS (
    SELECT risk_bin, COUNT(business_id) AS total_invited, AVG(fico_score) AS avg_fico_invite
    FROM invite_score
    GROUP BY risk_bin
),
MCA_approved AS (
    SELECT business_id, created_at, credit_limit / 100 AS offer_limit
    FROM fivetran_db.prod_novo_api_public.lending_businesses
    WHERE TO_CHAR(created_at, 'YYYY-MM-DD') >= '2026-05-29'
),
approved_profile AS (
    SELECT a.business_id, a.offer_limit, b.risk_bin, b.fico_score
    FROM MCA_approved a
    LEFT JOIN (
        SELECT * FROM prod_db.models.mca_uw_eligibility_base
        WHERE TO_CHAR(run_date, 'YYYY-MM') = '2026-05'
    ) b ON a.business_id = b.business_id
),
approved_by_bin AS (
    SELECT risk_bin, COUNT(business_id) AS total_approved, AVG(offer_limit) AS avg_offer_limit
    FROM approved_profile
    GROUP BY risk_bin
)
SELECT
    COALESCE(i.risk_bin, a.risk_bin)  AS risk_bin,
    COALESCE(i.total_invited, 0)       AS total_invited,
    i.avg_fico_invite,
    COALESCE(a.total_approved, 0)      AS total_approved,
    a.avg_offer_limit
FROM invite_by_bin i
FULL OUTER JOIN approved_by_bin a ON i.risk_bin = a.risk_bin
ORDER BY risk_bin
;


-- ------------------------------------------------------------
-- 11. MCA Monthly Revenue Summary
-- ------------------------------------------------------------
WITH business_grain AS (
    SELECT
        lt.business_id, lt.snap_date,
        MIN(lt.application_cohort)                 AS application_cohort,
        MAX(lt.days_past_due)                      AS days_past_due,
        SUM(lt.principal_balance_outstanding)      AS principal_balance_outstanding,
        SUM(lt.factor_fee_amount_paid_last_month)  AS factor_fee_collected,
        SUM(lt.fee_amount_paid_last_month)         AS late_fee_collected,
        SUM(lt.gross_principal_amount_charged_off) AS gaco_dollar,
        SUM(lt.net_principal_amount_charged_off)   AS naco_dollar
    FROM PROD_DB.DATA.LOAN_TAPE lt
    WHERE DAY(lt.snap_date) = 1
    GROUP BY 1, 2
),
enriched AS (
    SELECT
        bg.*,
        TO_CHAR(bg.snap_date - 1, 'YYYY-MM') AS report_month,
        CASE
            WHEN bg.application_cohort >= '2025-09'                    THEN 'CCR V2'
            WHEN bg.application_cohort BETWEEN '2024-09' AND '2025-08' THEN 'CCR V1'
            ELSE 'Pre-CCR'
        END AS underwriting_vintage,
        CASE
            WHEN COALESCE(bg.principal_balance_outstanding, 0) > 0
                THEN bg.principal_balance_outstanding
            WHEN (COALESCE(bg.gaco_dollar, 0) - COALESCE(bg.naco_dollar, 0)) > 0
                THEN bg.naco_dollar
            ELSE COALESCE(bg.gaco_dollar, 0)
        END AS co_value
    FROM business_grain bg
)
SELECT
    e.report_month,
    SUM(e.factor_fee_collected)                        AS factor_fee_collected,
    SUM(e.late_fee_collected)                          AS late_fee_collected,
    SUM(e.factor_fee_collected + e.late_fee_collected) AS revenue,
    SUM(CASE WHEN e.days_past_due BETWEEN 180 AND 209
             THEN e.co_value ELSE 0 END)               AS gaco,
    SUM(e.factor_fee_collected
        + e.late_fee_collected
        - CASE WHEN e.days_past_due BETWEEN 180 AND 209
               THEN e.co_value ELSE 0 END)             AS nibt
FROM enriched e
WHERE e.report_month IS NOT NULL
  AND e.report_month >= '2025-11'
GROUP BY 1
ORDER BY 1 DESC
;


-- ============================================================
-- END OF FILE
-- ============================================================
