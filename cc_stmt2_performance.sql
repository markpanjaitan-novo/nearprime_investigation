-- Statement 2 Performance Monitor
-- Grain: one row per campaign
-- Scope: accounts booked 2024-11 onwards; only cohorts where stmt2 due date has passed
-- Payment metrics: measured over the statement-2 payment window (issue date → due date)
-- Autopay enrollment: point-in-time as of statement-2 date
-- Activation: at least one settled transaction in the statement-2 billing window

with excluded_businesses as (
    select business_id
    from PROD_DB.DBT_OUTPUT.BUSINESS_GROUP_ASSIGNMENTS
    where business_group_id = '75fe98d2-6549-46a1-aa04-a1c621e21d9e'
),

booking as (
    select
         app.business_id
        ,min(to_char(app.created_at, 'YYYY-MM'))  as booking_month
    from FIVETRAN_DB.PROD_NOVO_API_PUBLIC.CREDIT_CARD_APPLICATIONS app
    join FIVETRAN_DB.PROD_NOVO_API_PUBLIC.CREDIT_CARD_ACCOUNTS ca
        on ca.business_id = app.business_id
    where app.status = 'APPROVED'
      and coalesce(ca._fivetran_deleted, false) = false
      and app.business_id not in (select business_id from excluded_businesses)
    group by 1
),

stmt2 as (
    select
         s.business_id
        ,s.created_at::date              as statement_date
        ,s.start_date::date              as billing_start
        ,s.end_date::date                as billing_end
        ,s.payment_due_date::date        as payment_due_date
        ,s.statement_balance  / 100.0    as statement_balance
        ,s.minimum_payment_due / 100.0   as min_payment_due
    from FIVETRAN_DB.PROD_NOVO_API_PUBLIC.CREDIT_CARD_STATEMENTS s
    where s.business_id not in (select business_id from excluded_businesses)
    qualify row_number() over (partition by s.business_id order by s.created_at asc) = 2
),

-- Loan tape at billing period 2, latest record version
tape_s2 as (
    select
         ca.business_id
        ,lt.ending_balance          / 100.0  as ending_balance
        ,lt.credit_limit            / 100.0  as credit_limit
        ,lt.period_purchases        / 100.0  as period_purchases
        ,lt.daily_balance_purchases::number / 100.0  as avg_daily_balance
        ,lt.days_past_due
        ,lt.grace_period
    from PROD_DB.DATA.CREDIT_CARD_ACCOUNT_LOAN_TAPE_HISTORY lt
    join FIVETRAN_DB.PROD_NOVO_API_PUBLIC.CREDIT_CARD_ACCOUNTS ca
        on ca.external_account_id = lt.account_id
    where lt.billing_period_number = 2
      and ca.business_id not in (select business_id from excluded_businesses)
    qualify row_number() over (
        partition by ca.business_id, lt.billing_period_number
        order by lt.statement_date desc, lt.record_version desc
    ) = 1
),

-- Settled payments in the statement-2 window: issue date → due date
pmts as (
    select
         p.business_id
        ,sum(p.amount) / 100.0  as total_paid
    from FIVETRAN_DB.PROD_NOVO_API_PUBLIC.CREDIT_CARD_PAYMENTS p
    join stmt2 s2
        on  s2.business_id     = p.business_id
        and p.created_at::date between s2.statement_date and s2.payment_due_date
    where p.status = 'settled'
    group by 1
),

-- Autopay enrollment as of statement-2 close date (point-in-time)
autopay as (
    select distinct ap.business_id
    from FIVETRAN_DB.PROD_NOVO_API_PUBLIC.CREDIT_CARD_AUTOPAY_INSTRUCTIONS ap
    join stmt2 s2
        on  s2.business_id        = ap.business_id
    where ap.created_at::date    <= s2.statement_date
      and (ap.status = 'active' or ap.updated_at::date > s2.statement_date)
),

-- Settled transactions during the statement-2 billing window
txns as (
    select
         tx.business_id
        ,count(*)                   as tx_count
        ,max(tx.created_at::date)   as last_tx_date
        ,max(s2.billing_end)        as billing_end
    from PROD_DB.DBT_OUTPUT.CREDIT_CARD_TRANSACTIONS tx
    join stmt2 s2
        on  s2.business_id     = tx.business_id
        and tx.created_at::date between s2.billing_start and s2.billing_end
    where tx.status = 'settled'
      and tx.business_id not in (select business_id from excluded_businesses)
    group by 1
),

-- FICO score at time of invitation (pre-approval, not refreshed)
fico as (
    select business_id, fico_score, to_char(created_at, 'YYYY-MM') as invite_month
    from FIVETRAN_DB.PROD_NOVO_API_PUBLIC.CREDIT_CARD_INVITATIONS
    qualify row_number() over (partition by business_id order by created_at desc) = 1
),

-- Interchange earned during the statement-2 billing window
interchange as (
    select
         ca.business_id
        ,sum(sri.interchange_gross_amount * -1) / 100.0  as interchange_dollars
    from FIVETRAN_DB.PROD_NOVO_API_PUBLIC.CREDIT_CARD_NOVO_SETTLEMENT_REPORT_ITEMS sri
    join FIVETRAN_DB.PROD_NOVO_API_PUBLIC.CREDIT_CARD_ACCOUNTS ca
        on ca.id = sri.credit_card_account_id
    join stmt2 s2
        on  s2.business_id           = ca.business_id
        and sri.report_date::date between s2.billing_start and s2.billing_end
    where ca.business_id not in (select business_id from excluded_businesses)
    group by 1
),

-- Cumulative spend: sum of period purchases across billing periods 1 and 2
cumulative_spend as (
    select
         business_id
        ,sum(period_purchases) / 100.0  as cumulative_purchases
    from (
        select
             ca.business_id
            ,lt.billing_period_number
            ,lt.period_purchases
        from PROD_DB.DATA.CREDIT_CARD_ACCOUNT_LOAN_TAPE_HISTORY lt
        join FIVETRAN_DB.PROD_NOVO_API_PUBLIC.CREDIT_CARD_ACCOUNTS ca
            on ca.external_account_id = lt.account_id
        where lt.billing_period_number in (1, 2)
          and ca.business_id not in (select business_id from excluded_businesses)
        qualify row_number() over (
            partition by ca.business_id, lt.billing_period_number
            order by lt.statement_date desc, lt.record_version desc
        ) = 1
    )
    group by 1
)

select
    case
        when fi.invite_month between '2024-11' and '2025-07' then 'Foundational Testing'
        when fi.invite_month between '2025-11' and '2026-01' then 'CART'
        when fi.invite_month >= '2026-03'                    then 'New Account Model'
        else 'Other'
    end                                                                      as campaign

    ,count(distinct s2.business_id)                                          as accounts_at_stmt2

    -- ── Payment behavior (stmt2) ─────────────────────────────────────────────
    -- Denominator for rate metrics: accounts with stmt2 balance > 0 (nothing owed → excluded)
    ,count(distinct case when s2.statement_balance > 0
                    then s2.business_id end)                                 as stmt2_had_balance

    -- Missed: had a balance, made no payment by due date
    ,count(distinct case when s2.statement_balance > 0
                          and coalesce(p.total_paid, 0) = 0
                    then s2.business_id end)                                 as missed_fp_count
    ,round(1
        * count(distinct case when s2.statement_balance > 0
                               and coalesce(p.total_paid, 0) = 0
                          then s2.business_id end)
        / nullif(count(distinct case when s2.statement_balance > 0
                                then s2.business_id end), 0), 1)            as missed_fp_rate_pct

    -- Min payment only: paid >= 90% of min due but < 90% of full balance
    ,count(distinct case when s2.statement_balance > 0
                          and coalesce(p.total_paid, 0) >= s2.min_payment_due * 0.9
                          and coalesce(p.total_paid, 0) <  s2.statement_balance * 0.9
                    then s2.business_id end)                                 as min_pmt_only_count
    ,round(100.0
        * count(distinct case when s2.statement_balance > 0
                               and coalesce(p.total_paid, 0) >= s2.min_payment_due * 0.9
                               and coalesce(p.total_paid, 0) <  s2.statement_balance * 0.9
                          then s2.business_id end)
        / nullif(count(distinct case when s2.statement_balance > 0
                                then s2.business_id end), 0), 1)            as min_pmt_only_rate_pct

    -- Paid in full: paid >= 90% of statement balance by due date
    ,count(distinct case when s2.statement_balance > 0
                          and coalesce(p.total_paid, 0) >= s2.statement_balance * 0.9
                    then s2.business_id end)                                 as paid_in_full_count
    ,round(100.0
        * count(distinct case when s2.statement_balance > 0
                               and coalesce(p.total_paid, 0) >= s2.statement_balance * 0.9
                          then s2.business_id end)
        / nullif(count(distinct case when s2.statement_balance > 0
                                then s2.business_id end), 0), 1)            as paid_in_full_rate_pct

    -- Average payment ratio: what fraction of the balance was paid; null for $0 balances
    ,round(avg(case when s2.statement_balance > 0
                    then coalesce(p.total_paid, 0) / s2.statement_balance
               end), 3)                                                      as avg_payment_ratio

    ,round(100.0
        * count(distinct ap.business_id)
        / nullif(count(distinct s2.business_id), 0), 1)                     as autopay_enrollment_rate_pct

    -- ── Balance & utilization (period 2) ─────────────────────────────────────
    ,round(avg(cs.cumulative_purchases), 2)                                  as avg_cumulative_purchase_volume
    ,round(sum(t.period_purchases), 2)                                       as total_purchase_volume
    ,round(
        sum(case when t.ending_balance > 0 then t.ending_balance end)
        / nullif(sum(case when t.ending_balance > 0 then t.credit_limit end), 0)
    , 3)                                                                     as avg_utilization_rate
    ,round(avg(t.avg_daily_balance), 2)                                      as avg_daily_balance

    -- ── Activation & engagement (period 2) ───────────────────────────────────
    -- Activation: had at least one settled transaction in the stmt2 billing window
    ,round(100.0
        * count(distinct case when tx.tx_count > 0 then s2.business_id end)
        / nullif(count(distinct s2.business_id), 0), 1)                     as activation_rate_pct

    ,round(avg(coalesce(tx.tx_count, 0)), 1)                                as avg_tx_count
    ,round(avg(case
               when tx.last_tx_date is not null
               then datediff('day', tx.last_tx_date, tx.billing_end)
               end), 1)                                                      as avg_days_since_last_tx

    -- ── Revenue (period 2) ───────────────────────────────────────────────────
    ,round(avg(ix.interchange_dollars), 2)                                   as avg_interchange

    -- ── Portfolio composition ────────────────────────────────────────────────
    ,round(avg(fi.fico_score), 0)                                            as avg_fico
    ,min(b.booking_month)                                                    as first_booking_month

from stmt2           s2
join  booking        b   on  b.business_id   = s2.business_id
left  join tape_s2   t   on  t.business_id   = s2.business_id
left  join pmts      p   on  p.business_id   = s2.business_id
left  join autopay   ap  on  ap.business_id  = s2.business_id
left  join txns      tx  on  tx.business_id  = s2.business_id
left  join fico      fi  on  fi.business_id  = s2.business_id
left  join interchange ix on  ix.business_id = s2.business_id
left  join cumulative_spend cs on cs.business_id = s2.business_id

where b.booking_month >= '2024-11'
  and s2.payment_due_date < current_date()

group by 1
order by first_booking_month
;