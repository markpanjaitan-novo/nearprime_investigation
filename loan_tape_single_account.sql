-- Single-account loan tape diagnostic
-- Swap the business_id literal in `target` to inspect a different account.
-- Default: one account booked in April 2025.

with target as (
    select ca.business_id, ca.external_account_id
    from FIVETRAN_DB.PROD_NOVO_API_PUBLIC.CREDIT_CARD_APPLICATIONS app
    join FIVETRAN_DB.PROD_NOVO_API_PUBLIC.CREDIT_CARD_ACCOUNTS ca
        on ca.business_id = app.business_id
    where app.status = 'APPROVED'
      and to_char(app.created_at, 'YYYY-MM') = '2025-04'
      and coalesce(ca._fivetran_deleted, false) = false
    qualify row_number() over (order by app.created_at) = 1
)

-- ── Result 1: per-billing-period summary (run this block on its own) ─────────
-- Tape and statement joined side by side, latest record version per period only
select
     lt.billing_period_number                          as period
    ,s.start_date::date                                as billing_start
    ,s.end_date::date                                  as billing_end
    ,s.payment_due_date::date                          as payment_due_date

    -- Statement-level
    ,s.statement_balance     / 100.0                   as stmt_balance
    ,s.minimum_payment_due   / 100.0                   as min_payment_due

    -- Tape-level (latest record version)
    ,lt.period_purchases         / 100.0               as period_purchases
    ,lt.daily_balance_purchases::number / 100.0        as avg_daily_balance
    ,lt.ending_balance           / 100.0               as ending_balance
    ,lt.credit_limit             / 100.0               as credit_limit
    ,round(lt.ending_balance / nullif(lt.credit_limit, 0), 3)
                                                       as utilization
    ,lt.days_past_due
    ,lt.grace_period
    ,lt.record_version

from PROD_DB.DATA.CREDIT_CARD_ACCOUNT_LOAN_TAPE_HISTORY lt
join target t
    on t.external_account_id = lt.account_id
-- join statements to get billing window dates; seq matches billing_period_number
join (
    select
         business_id
        ,start_date, end_date, payment_due_date, statement_balance, minimum_payment_due
        ,row_number() over (partition by business_id order by created_at asc) as stmt_seq
    from FIVETRAN_DB.PROD_NOVO_API_PUBLIC.CREDIT_CARD_STATEMENTS
) s
    on  s.business_id = t.business_id
    and s.stmt_seq    = lt.billing_period_number

qualify row_number() over (
    partition by lt.billing_period_number
    order by lt.statement_date desc, lt.record_version desc
) = 1

order by lt.billing_period_number
;


-- ── Result 2: all payments (run this block on its own) ───────────────────────
select
     p.created_at::date   as payment_date
    ,p.amount / 100.0     as amount
    ,p.status
from FIVETRAN_DB.PROD_NOVO_API_PUBLIC.CREDIT_CARD_PAYMENTS p
join (
    select ca.business_id
    from FIVETRAN_DB.PROD_NOVO_API_PUBLIC.CREDIT_CARD_APPLICATIONS app
    join FIVETRAN_DB.PROD_NOVO_API_PUBLIC.CREDIT_CARD_ACCOUNTS ca
        on ca.business_id = app.business_id
    where app.status = 'APPROVED'
      and to_char(app.created_at, 'YYYY-MM') = '2025-04'
      and coalesce(ca._fivetran_deleted, false) = false
    qualify row_number() over (order by app.created_at) = 1
) t on t.business_id = p.business_id
order by p.created_at
;


-- ── Result 3: raw tape (all record versions) — useful if Result 1 looks off ──
select
     lt.billing_period_number
    ,lt.record_version
    ,lt.statement_date::date                            as tape_statement_date
    ,lt.period_purchases         / 100.0               as period_purchases
    ,lt.daily_balance_purchases::number / 100.0        as avg_daily_balance
    ,lt.ending_balance           / 100.0               as ending_balance
    ,lt.days_past_due
    ,lt.grace_period
from PROD_DB.DATA.CREDIT_CARD_ACCOUNT_LOAN_TAPE_HISTORY lt
join (
    select ca.external_account_id
    from FIVETRAN_DB.PROD_NOVO_API_PUBLIC.CREDIT_CARD_APPLICATIONS app
    join FIVETRAN_DB.PROD_NOVO_API_PUBLIC.CREDIT_CARD_ACCOUNTS ca
        on ca.business_id = app.business_id
    where app.status = 'APPROVED'
      and to_char(app.created_at, 'YYYY-MM') = '2025-04'
      and coalesce(ca._fivetran_deleted, false) = false
    qualify row_number() over (order by app.created_at) = 1
) t on t.external_account_id = lt.account_id
order by lt.billing_period_number, lt.record_version
;