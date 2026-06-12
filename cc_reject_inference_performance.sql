-- Statement 1 Performance by Risk Bucket — 2026-03+ Cohorts
--
-- Population: all accounts booked 2026-03 onwards (new account model era).
-- Grouped by risk_bucket so RI can be compared directly against scored buckets 1–5.
--
-- Risk bucket logic mirrors 01_risk_bucket_lookup.sql:
--   last invite = 2026-04  →  apr score, fallback retro
--   last invite = 2026-05  →  may score, fallback apr
--   all other              →  retro score
--   NULL in all tables     →  'Reject Inference'
--   Not in any score table →  'Reject Inference' (via COALESCE on left join)
--
-- Missed FP: among accounts whose first billing period closed with a balance > 0,
--            count those that made no settled payment by the statement due date.
--            (DPD is always 0 at billing period 1, so payment-based is the only option.)
--
-- Fully baked stmt1 only: stmt1 metrics count an account only once its stmt1
-- payment due date has passed (per-account filter, applied in the stmt1 join).
-- total_booked still counts ALL booked accounts — including those with no
-- statement yet — so the funnel from booked → baked stmt1 stays visible.

with excluded_businesses as (
    select business_id
    from PROD_DB.DBT_OUTPUT.BUSINESS_GROUP_ASSIGNMENTS
    where business_group_id = '75fe98d2-6549-46a1-aa04-a1c621e21d9e'
),

-- ── Risk-bucket lookup (inline from 01_risk_bucket_lookup.sql) ───────────────
latest_invite as (
    select business_id, max(created_at) as last_invite_at
    from FIVETRAN_DB.PROD_NOVO_API_PUBLIC.CREDIT_CARD_INVITATIONS
    group by 1
),

risk_bucket_lookup as (
    select
         b.business_id
        ,coalesce(
            case
                when to_char(li.last_invite_at, 'YYYY-MM') = '2026-04'
                    then coalesce(apr.final_risk_bucket::text, retro.final_risk_bucket::text)
                when to_char(li.last_invite_at, 'YYYY-MM') = '2026-05'
                    then coalesce(may."final_risk_bucket"::text, apr.final_risk_bucket::text)
                else retro.final_risk_bucket::text
            end,
            'Reject Inference'
        ) as risk_bucket
    from (
        select business_id from PROD_DB.ADHOC.RISK_BUCKET_RETRO_SCORE_MAY4
        union
        select business_id from PROD_DB.ADHOC.CC_APR_CAMPAIGN_MODEL_BUCKET
        union
        select business_id from PROD_DB.DE.CC_NEW_ACCOUNT_MODEL_UW
    ) b
    left join latest_invite                                li    on li.business_id    = b.business_id
    left join PROD_DB.ADHOC.RISK_BUCKET_RETRO_SCORE_MAY4  retro on retro.business_id = b.business_id
    left join PROD_DB.ADHOC.CC_APR_CAMPAIGN_MODEL_BUCKET  apr   on apr.business_id   = b.business_id
    left join PROD_DB.DE.CC_NEW_ACCOUNT_MODEL_UW          may   on may.business_id   = b.business_id
),

-- ── Account universe ─────────────────────────────────────────────────────────
acct_dedup as (
    select
         a.business_id
        ,a.external_account_id
        ,row_number() over (
             partition by a.external_account_id
             order by     a.created_at desc
         ) as rn_dup
    from FIVETRAN_DB.PROD_NOVO_API_PUBLIC.CREDIT_CARD_ACCOUNTS a
    where coalesce(a._fivetran_deleted, false) = false
),

acct as (
    select business_id, external_account_id,
           row_number() over (partition by business_id order by external_account_id) as rn
    from acct_dedup
    where rn_dup = 1
),

app_booking as (
    select business_id, min(created_at) as created_at
    from FIVETRAN_DB.PROD_NOVO_API_PUBLIC.CREDIT_CARD_APPLICATIONS
    where status = 'APPROVED'
    group by 1
),

booking as (
    select
         a.business_id
        ,a.external_account_id
        ,app.created_at::date                            as booking_date
        ,to_char(app.created_at, 'YYYY-MM')              as booking_month
        ,coalesce(rb.risk_bucket, 'Reject Inference')    as risk_bucket
    from acct a
    join  app_booking           app on app.business_id = a.business_id
    left join risk_bucket_lookup rb  on rb.business_id  = a.business_id
    where a.rn = 1
      and to_char(app.created_at, 'YYYY-MM') >= '2026-03'
      and a.business_id not in (select business_id from excluded_businesses)
),

-- ── Statements ───────────────────────────────────────────────────────────────
stmt1 as (
    select
         s.business_id
        ,s.created_at::date              as statement_date
        ,s.start_date::date              as billing_start
        ,s.end_date::date                as billing_end
        ,s.payment_due_date::date        as payment_due_date
        ,s.statement_balance  / 100.0    as statement_balance
        ,s.minimum_payment_due / 100.0   as min_payment_due
        ,row_number() over (partition by s.business_id order by s.created_at asc) as rn
    from FIVETRAN_DB.PROD_NOVO_API_PUBLIC.CREDIT_CARD_STATEMENTS s
    join booking b on b.business_id = s.business_id
    qualify rn = 1
),

-- ── Loan tape at billing period 1 ────────────────────────────────────────────
tape_s1 as (
    select
         b.business_id
        ,lt.ending_balance          / 100.0              as ending_balance
        ,lt.credit_limit            / 100.0              as credit_limit
        ,lt.period_purchases        / 100.0              as period_purchases
        ,lt.daily_balance_purchases::number / 100.0      as avg_daily_balance
        ,lt.days_past_due
    from PROD_DB.DATA.CREDIT_CARD_ACCOUNT_LOAN_TAPE_HISTORY lt
    join booking b on b.external_account_id = lt.account_id
    where lt.billing_period_number = 1
    qualify row_number() over (
        partition by b.business_id
        order by lt.statement_date desc, lt.record_version desc
    ) = 1
),

-- ── Payments in the stmt1 window ─────────────────────────────────────────────
pmts as (
    select
         p.business_id
        ,sum(p.amount) / 100.0  as total_paid
    from FIVETRAN_DB.PROD_NOVO_API_PUBLIC.CREDIT_CARD_PAYMENTS p
    join stmt1 s1
        on  s1.business_id     = p.business_id
        and p.created_at::date between s1.statement_date and s1.payment_due_date
    where p.status = 'settled'
    group by 1
),

-- Settled payments in the late-cure window: day after due date → due date + 21.
-- For accounts whose 21-day window hasn't fully elapsed yet, this naturally
-- captures everything settled to date (no payments exist in the future), so
-- open windows contribute their most current payment picture.
late_pmts as (
    select
         p.business_id
        ,sum(p.amount) / 100.0  as total_paid
    from FIVETRAN_DB.PROD_NOVO_API_PUBLIC.CREDIT_CARD_PAYMENTS p
    join stmt1 s1
        on  s1.business_id     = p.business_id
        and p.created_at::date >  s1.payment_due_date
        and p.created_at::date <= dateadd(day, 21, s1.payment_due_date)
    where p.status = 'settled'
    group by 1
),

fico as (
    select business_id, fico_score
    from FIVETRAN_DB.PROD_NOVO_API_PUBLIC.CREDIT_CARD_INVITATIONS
    qualify row_number() over (partition by business_id order by created_at desc) = 1
),

txns as (
    select
         tx.business_id
        ,count(*) as tx_count
    from PROD_DB.DBT_OUTPUT.CREDIT_CARD_TRANSACTIONS tx
    join stmt1 s1
        on  s1.business_id     = tx.business_id
        and tx.created_at::date between s1.billing_start and s1.billing_end
    where tx.status = 'settled'
      and tx.business_id not in (select business_id from excluded_businesses)
    group by 1
)

select
     b.risk_bucket
    ,round(avg(f.fico_score), 0)                                            as avg_fico
    ,count(distinct b.business_id)                                          as total_booked
    ,count(distinct s1.business_id)                                          as accounts_at_stmt1

    -- ── Payment behavior ────────────────────────────────────────────────────
    -- Universe for both metrics: accounts with a non-zero stmt1 balance
    -- (statement-based, not loan tape — the tape has coverage gaps)
    ,count(distinct case when s1.statement_balance > 0
                    then s1.business_id end)                                 as accounts_with_balance

    -- Missed FP: had a stmt1 balance but no payment received by the due date
    ,round(1
        * count(distinct case when s1.statement_balance > 0
                               and coalesce(p.total_paid, 0) = 0
                          then s1.business_id end)
        / nullif(count(distinct case when s1.statement_balance > 0
                                then s1.business_id end), 0), 3)            as missed_fp_rate_pct

    ,round(1
        * count(distinct case when s1.statement_balance > 0
                               and coalesce(p.total_paid, 0) >= s1.statement_balance * 0.9
                          then s1.business_id end)
        / nullif(count(distinct case when s1.statement_balance > 0
                                then s1.business_id end), 0), 3)            as full_repayment_rate_pct

    -- Delinquent at due date: had a stmt1 balance but paid nothing — or less
    -- than the minimum due — by the due date.
    ,count(distinct case when s1.statement_balance > 0
                          and coalesce(p.total_paid, 0) < s1.min_payment_due
                    then s1.business_id end)                                 as delinquent_at_due_count

    -- Late cure: delinquent at due date, then cumulative payments (on-time
    -- partial + late) reached the minimum due within 21 days after the due
    -- date. Accounts whose 21-day window is still open are included with
    -- their payments to date rather than excluded.
    ,count(distinct case when s1.statement_balance > 0
                          and coalesce(p.total_paid, 0) < s1.min_payment_due
                          and coalesce(p.total_paid, 0) + coalesce(lp.total_paid, 0) >= s1.min_payment_due
                    then s1.business_id end)                                 as cured_within_21d_count
    ,round(1
        * count(distinct case when s1.statement_balance > 0
                               and coalesce(p.total_paid, 0) < s1.min_payment_due
                               and coalesce(p.total_paid, 0) + coalesce(lp.total_paid, 0) >= s1.min_payment_due
                          then s1.business_id end)
        / nullif(count(distinct case when s1.statement_balance > 0
                                      and coalesce(p.total_paid, 0) < s1.min_payment_due
                                then s1.business_id end), 0), 3)            as cured_within_21d_rate

    -- ── Balance & utilization ────────────────────────────────────────────────
    -- Gated on s1 so the universe matches the baked stmt1 population
    ,round(avg(case when s1.business_id is not null
               then t1.credit_limit end), 2)                                as avg_credit_line

    ,round(avg(case when s1.business_id is not null
               then t1.avg_daily_balance end), 2)                           as avg_adb

    ,round(avg(case when s1.business_id is not null
               then t1.period_purchases end), 2)                            as avg_spend

    ,round(avg(case when s1.business_id is not null and t1.credit_limit > 0
               then t1.ending_balance / t1.credit_limit end), 3)            as avg_util

    -- Transactor-only views: same metrics restricted to accounts with at
    -- least one settled transaction in the stmt1 billing window, so idle
    -- (never-swiped) accounts don't drag the averages toward zero
    ,round(avg(case when s1.business_id is not null and tx.tx_count > 0
                     and t1.credit_limit > 0
               then t1.ending_balance / t1.credit_limit end), 3)            as avg_util_transactors

    ,round(avg(case when s1.business_id is not null and tx.tx_count > 0
               then t1.avg_daily_balance end), 2)                           as avg_adb_transactors

    -- ── Activation ───────────────────────────────────────────────────────────
    -- Uses transactions, not loan tape, to avoid tape coverage gaps
    ,round(1
        * count(distinct case when tx.tx_count > 0 then s1.business_id end)
        / nullif(count(distinct s1.business_id), 0), 3)                    as activation_rate_pct
    
    ,min(b.booking_date)                                                    as first_booking_month  
    ,round( count(distinct case when s1.statement_balance > 0
                               and coalesce(p.total_paid, 0) = 0
                          then s1.business_id end),1
                          ) as number_of_missed_fp
    ,round(avg(case when s1.business_id is not null and t1.period_purchases > 0
               then t1.period_purchases end), 2)                            as avg_spend_above_0
from booking       b
left join tape_s1  t1  on  t1.business_id = b.business_id
-- baked filter lives in the join (not WHERE) so unbaked accounts stay in
-- total_booked but drop out of every stmt1-gated metric
left join stmt1    s1  on  s1.business_id = b.business_id
                       and s1.payment_due_date < current_date()
left join pmts     p   on  p.business_id  = b.business_id
left join late_pmts lp on  lp.business_id = b.business_id
left join fico     f   on  f.business_id  = b.business_id
left join txns     tx  on  tx.business_id = b.business_id
group by 1
order by
    case b.risk_bucket
        when '1' then 1 when '2' then 2 when '3' then 3
        when '4' then 4 when '5' then 5 else 6
    end
;
