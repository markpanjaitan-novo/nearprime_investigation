-- ============================================================================
-- CC Rewards Outstanding Balance — Month-over-Month
--
-- Shows total unredeemed rewards held by customers at the end of each month.
-- Outstanding balance = cumulative accruals - cumulative successful redemptions.
--
-- Grain: one row per report_month.
--
-- Key columns:
--   accrued_this_month   — new rewards earned during the month (cash-back on purchases)
--   redeemed_this_month  — rewards cashed out during the month (posted_at date)
--   net_change           — accrued minus redeemed for the month
--   outstanding_balance  — running cumulative unredeemed balance (the main metric)
--   cumulative_accrued   — all rewards ever earned through this month
--   cumulative_redeemed  — all rewards ever redeemed through this month
--   accounts_earning     — distinct accounts that earned rewards this month
--   accounts_redeeming   — distinct accounts that redeemed this month
--
-- Tables — no ADHOC dependencies:
--   FIVETRAN_DB.PROD_NOVO_API_PUBLIC.CREDIT_CARD_TRANSACTION_REWARD_ITEMS
--   FIVETRAN_DB.PROD_NOVO_API_PUBLIC.CREDIT_CARD_REWARD_REDEMPTIONS
--   FIVETRAN_DB.PROD_NOVO_API_PUBLIC.CREDIT_CARD_ACCOUNTS
--   FIVETRAN_DB.PROD_NOVO_API_PUBLIC.BUSINESS_GROUP_ASSIGNMENTS
-- ============================================================================

WITH

excluded_businesses AS (
    SELECT business_id
    FROM FIVETRAN_DB.PROD_NOVO_API_PUBLIC.BUSINESS_GROUP_ASSIGNMENTS
    WHERE business_group_id = '75fe98d2-6549-46a1-aa04-a1c621e21d9e'
),

-- Dedupe on external_account_id first (Fivetran versioning), then one per business_id
dedup_accts AS (
    SELECT
        a.business_id,
        a.id AS cc_account_id
    FROM FIVETRAN_DB.PROD_NOVO_API_PUBLIC.CREDIT_CARD_ACCOUNTS a
    WHERE COALESCE(a._fivetran_deleted, FALSE) = FALSE
      AND a.business_id NOT IN (SELECT business_id FROM excluded_businesses)
    QUALIFY ROW_NUMBER() OVER (
        PARTITION BY a.external_account_id
        ORDER BY     a.created_at DESC
    ) = 1
),

account_base AS (
    SELECT business_id, cc_account_id
    FROM dedup_accts
    QUALIFY ROW_NUMBER() OVER (
        PARTITION BY business_id
        ORDER BY     cc_account_id
    ) = 1
),

-- Rewards earned per month (accrual events, one row per transaction)
monthly_accruals AS (
    SELECT
        TO_CHAR(DATE_TRUNC('month', ri.created_at), 'YYYY-MM') AS report_month,
        COUNT(DISTINCT ab.business_id)                          AS accounts_earning,
        SUM(ri.rewards)                                         AS accrued_cents
    FROM FIVETRAN_DB.PROD_NOVO_API_PUBLIC.CREDIT_CARD_TRANSACTION_REWARD_ITEMS ri
    JOIN account_base ab ON ab.cc_account_id = ri.credit_card_account_id
    WHERE COALESCE(ri._fivetran_deleted, FALSE) = FALSE
    GROUP BY 1
),

-- Rewards redeemed per month (successful settlements only; use posted_at as the settlement date)
monthly_redemptions AS (
    SELECT
        TO_CHAR(DATE_TRUNC('month', COALESCE(rd.posted_at, rd.created_at)), 'YYYY-MM') AS report_month,
        COUNT(DISTINCT ab.business_id)                                                  AS accounts_redeeming,
        SUM(rd.rewards)                                                                 AS redeemed_cents
    FROM FIVETRAN_DB.PROD_NOVO_API_PUBLIC.CREDIT_CARD_REWARD_REDEMPTIONS rd
    JOIN account_base ab ON ab.cc_account_id = rd.credit_card_account_id
    WHERE rd.status = 'success'
      AND COALESCE(rd._fivetran_deleted, FALSE) = FALSE
    GROUP BY 1
),

-- Month spine driven by actual activity (no gaps from static date ranges)
month_spine AS (
    SELECT report_month FROM monthly_accruals
    UNION
    SELECT report_month FROM monthly_redemptions
),

monthly AS (
    SELECT
        ms.report_month,
        COALESCE(ma.accounts_earning,   0) AS accounts_earning,
        COALESCE(mr.accounts_redeeming, 0) AS accounts_redeeming,
        COALESCE(ma.accrued_cents,      0) AS accrued_cents,
        COALESCE(mr.redeemed_cents,     0) AS redeemed_cents,
        COALESCE(ma.accrued_cents, 0)
            - COALESCE(mr.redeemed_cents, 0)  AS net_cents_this_month
    FROM month_spine ms
    LEFT JOIN monthly_accruals    ma ON ma.report_month = ms.report_month
    LEFT JOIN monthly_redemptions mr ON mr.report_month = ms.report_month
)

SELECT
    report_month,
    ROUND(accrued_cents        / 100.0, 2)   AS accrued_this_month,
    ROUND(redeemed_cents       / 100.0, 2)   AS redeemed_this_month,
    ROUND(net_cents_this_month / 100.0, 2)   AS net_change,
    -- Running cumulative unredeemed balance — the main metric
    ROUND(SUM(net_cents_this_month) OVER (
        ORDER BY report_month
        ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
    ) / 100.0, 2)                            AS outstanding_balance,
    ROUND(SUM(accrued_cents)        OVER (
        ORDER BY report_month
        ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
    ) / 100.0, 2)                            AS cumulative_accrued,
    ROUND(SUM(redeemed_cents)       OVER (
        ORDER BY report_month
        ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
    ) / 100.0, 2)                            AS cumulative_redeemed,
    accounts_earning,
    accounts_redeeming
FROM monthly
ORDER BY report_month
;