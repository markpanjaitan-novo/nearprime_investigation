-- ============================================================================
-- CC Rewards Forfeiture Report
-- One row per account that forfeited unredeemed rewards due to one of:
--
--   CHARGED_OFF  — DPD >= 180 at most recent loan tape entry (takes priority
--                  over account status; charged-off accounts surface as
--                  'closed', 'delinquent', or 'suspended' in the accounts table)
--   CLOSED       — status = 'closed' AND DPD < 180
--   SUSPENDED    — status = 'suspended' AND DPD < 180
--   INACTIVE     — last-statement TRIP = 'I' (zero principal balance AND zero
--                  period purchases) AND account open >= 6 months
--
-- Forfeited balance = available_rewards + pending_rewards from
-- CREDIT_CARD_ACCOUNT_REWARDS (net of redemptions; cents → dollars).
-- redeemed_rewards is included for context only.
--
-- Tables used — no ADHOC dependencies:
--   FIVETRAN_DB.PROD_NOVO_API_PUBLIC.CREDIT_CARD_ACCOUNTS
--   FIVETRAN_DB.PROD_NOVO_API_PUBLIC.CREDIT_CARD_APPLICATIONS
--   FIVETRAN_DB.PROD_NOVO_API_PUBLIC.BUSINESS_GROUP_ASSIGNMENTS
--   FIVETRAN_DB.PROD_NOVO_API_PUBLIC.CREDIT_CARD_ACCOUNT_REWARDS
--   PROD_DB.DATA.CREDIT_CARD_ACCOUNT_LOAN_TAPE_HISTORY
-- ============================================================================

WITH

excluded_businesses AS (
    SELECT business_id
    FROM FIVETRAN_DB.PROD_NOVO_API_PUBLIC.BUSINESS_GROUP_ASSIGNMENTS
    WHERE business_group_id = '75fe98d2-6549-46a1-aa04-a1c621e21d9e'
),

-- One row per external_account_id — latest Fivetran version
dedup_accts AS (
    SELECT
        a.business_id,
        a.external_account_id,
        a.id         AS cc_account_id,
        a.status,
        a.updated_at AS status_updated_at
    FROM FIVETRAN_DB.PROD_NOVO_API_PUBLIC.CREDIT_CARD_ACCOUNTS a
    WHERE COALESCE(a._fivetran_deleted, FALSE) = FALSE
    QUALIFY ROW_NUMBER() OVER (
        PARTITION BY a.external_account_id
        ORDER BY     a.created_at DESC
    ) = 1
),

-- One row per business_id (earliest account), F&F excluded
account_base AS (
    SELECT
        d.business_id,
        d.external_account_id,
        d.cc_account_id,
        d.status,
        d.status_updated_at
    FROM dedup_accts d
    WHERE d.business_id NOT IN (SELECT business_id FROM excluded_businesses)
    QUALIFY ROW_NUMBER() OVER (
        PARTITION BY d.business_id
        ORDER BY     d.cc_account_id
    ) = 1
),

-- Booking date = earliest approved application per business
booking AS (
    SELECT
        business_id,
        MIN(created_at)                     AS booking_date,
        TO_CHAR(MIN(created_at), 'YYYY-MM') AS booking_month
    FROM FIVETRAN_DB.PROD_NOVO_API_PUBLIC.CREDIT_CARD_APPLICATIONS
    WHERE status = 'APPROVED'
    GROUP BY 1
),

-- Most recent loan tape row per account (DPD, balances, TRIP inputs)
latest_tape AS (
    SELECT
        ab.business_id,
        h.days_past_due,
        h.statement_date::DATE   AS last_statement_date,
        h.billing_period_number  AS last_billing_period,
        h.grace_period,
        h.period_purchases       AS period_purchases_cents,
        (
            COALESCE(h.next_due_principal,        0)
          + COALESCE(h.past_statements_principal, 0)
          + COALESCE(h.due_principal,             0)
          + COALESCE(h.past_due_principal,        0)
        )                        AS pbo_cents,
        h.ending_balance         AS ending_balance_cents,
        h.credit_limit           AS credit_limit_cents
    FROM PROD_DB.DATA.CREDIT_CARD_ACCOUNT_LOAN_TAPE_HISTORY h
    JOIN account_base ab ON ab.external_account_id = h.account_id
    WHERE h.billing_period_number >= 1
    QUALIFY ROW_NUMBER() OVER (
        PARTITION BY ab.business_id
        ORDER BY h.statement_date DESC, h.record_version DESC
    ) = 1
),

-- Current reward balances per account (already net of redemptions)
account_rewards AS (
    SELECT
        ar.credit_card_account_id                       AS cc_account_id,
        ROUND(ar.available_rewards / 100.0, 2)          AS available_rewards_dollars,
        ROUND(ar.pending_rewards   / 100.0, 2)          AS pending_rewards_dollars,
        ROUND(ar.redeemed_rewards  / 100.0, 2)          AS redeemed_rewards_dollars
    FROM FIVETRAN_DB.PROD_NOVO_API_PUBLIC.CREDIT_CARD_ACCOUNT_REWARDS ar
    WHERE COALESCE(ar._fivetran_deleted, FALSE) = FALSE
),

-- Assemble all dimensions and derive forfeiture reason
classified AS (
    SELECT
        ab.business_id,
        ab.external_account_id,
        ab.status                                                      AS account_status,
        ab.status_updated_at::DATE                                     AS status_updated_date,
        bk.booking_date::DATE                                          AS booking_date,
        bk.booking_month,
        lt.last_statement_date,
        lt.last_billing_period,
        lt.days_past_due                                               AS last_dpd,
        lt.pbo_cents            / 100.0                                AS last_pbo_dollars,
        lt.ending_balance_cents / 100.0                                AS last_ending_balance_dollars,
        lt.credit_limit_cents   / 100.0                                AS credit_limit_dollars,
        DATEDIFF('month', bk.booking_date, CURRENT_DATE)               AS months_since_booking,
        -- TRIP class at last statement — mirrors 29_cc_eom_trip_driver.sql logic
        CASE
            WHEN COALESCE(lt.pbo_cents, 0)              = 0
             AND COALESCE(lt.period_purchases_cents, 0) = 0   THEN 'I'
            WHEN lt.grace_period = TRUE                        THEN 'T'
            WHEN COALESCE(lt.grace_period, FALSE) = FALSE
             AND lt.period_purchases_cents > 0                 THEN 'R'
            ELSE                                                    'P'
        END                                                            AS last_trip_class,
        -- Reward balances (net of redemptions, from CREDIT_CARD_ACCOUNT_REWARDS)
        COALESCE(ar.available_rewards_dollars, 0)                      AS available_rewards_dollars,
        COALESCE(ar.pending_rewards_dollars,   0)                      AS pending_rewards_dollars,
        COALESCE(ar.redeemed_rewards_dollars,  0)                      AS redeemed_rewards_dollars,
        -- Forfeited = available + pending (both lost at closure/charge-off)
        COALESCE(ar.available_rewards_dollars, 0)
            + COALESCE(ar.pending_rewards_dollars, 0)                  AS forfeited_rewards_dollars,
        -- Forfeiture classification (evaluated in priority order)
        -- Note: charged-off accounts appear as 'closed'/'delinquent'/'suspended'
        -- in CREDIT_CARD_ACCOUNTS — DPD from the loan tape is the authoritative signal.
        CASE
            WHEN lt.days_past_due >= 180
                THEN 'CHARGED_OFF'
            WHEN ab.status = 'closed'
                THEN 'CLOSED'
            WHEN ab.status = 'suspended'
                THEN 'SUSPENDED'
            WHEN COALESCE(lt.pbo_cents, 0)              = 0
             AND COALESCE(lt.period_purchases_cents, 0) = 0
             AND DATEDIFF('month', bk.booking_date, CURRENT_DATE) >= 6
                THEN 'INACTIVE'
            ELSE NULL
        END                                                            AS forfeiture_reason
    FROM account_base ab
    LEFT JOIN booking        bk ON bk.business_id   = ab.business_id
    LEFT JOIN latest_tape    lt ON lt.business_id   = ab.business_id
    LEFT JOIN account_rewards ar ON ar.cc_account_id = ab.cc_account_id
)

-- ── Detail: one row per account with forfeited rewards ───────────────────────
SELECT
    business_id,
    external_account_id,
    forfeiture_reason,
    account_status,
    status_updated_date,
    booking_date,
    booking_month,
    last_statement_date,
    last_billing_period,
    last_dpd,
    last_trip_class,
    last_pbo_dollars,
    last_ending_balance_dollars,
    credit_limit_dollars,
    available_rewards_dollars,
    pending_rewards_dollars,
    forfeited_rewards_dollars,
    redeemed_rewards_dollars,
    months_since_booking
FROM classified
WHERE forfeiture_reason IS NOT NULL
  AND forfeited_rewards_dollars > 0
ORDER BY
    forfeiture_reason,
    forfeited_rewards_dollars DESC
;

-- ── Summary: total forfeited dollars and account count by reason ─────────────
-- Uncomment and run separately to get the aggregate view.
--
-- SELECT
--     forfeiture_reason,
--     COUNT(*)                                    AS account_count,
--     ROUND(SUM(forfeited_rewards_dollars), 2)    AS total_forfeited_dollars,
--     ROUND(AVG(forfeited_rewards_dollars), 2)    AS avg_forfeited_per_account,
--     ROUND(MAX(forfeited_rewards_dollars), 2)    AS max_forfeited_per_account
-- FROM (
--     SELECT forfeiture_reason, forfeited_rewards_dollars
--     FROM classified
--     WHERE forfeiture_reason IS NOT NULL
--       AND forfeited_rewards_dollars > 0
-- )
-- GROUP BY 1
-- ORDER BY total_forfeited_dollars DESC
-- ;