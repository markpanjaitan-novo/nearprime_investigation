-- Interim late-cure tracker for Reject Inference missed-FP accounts
-- Grain: one row per stmt1 payment due date
--
-- Shows, for RI accounts that had a stmt1 balance and made no settled payment
-- by the due date, how many have ALREADY paid at least their minimum due in
-- the late window — even though their 14-day cure window is still open.
-- This is the live view behind cured_before_dpd14_rate in
-- cc_reject_inference_performance.sql, which only scores an account once its
-- full window has elapsed. Swap the risk_bucket filter at the bottom to
-- inspect other buckets.

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

-- ── Account universe (booked 2026-03+, F&F excluded) ─────────────────────────
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
    select business_id,
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
        ,coalesce(rb.risk_bucket, 'Reject Inference')    as risk_bucket
    from acct a
    join  app_booking           app on app.business_id = a.business_id
    left join risk_bucket_lookup rb  on rb.business_id  = a.business_id
    where a.rn = 1
      and to_char(app.created_at, 'YYYY-MM') >= '2026-03'
      and a.business_id not in (select business_id from excluded_businesses)
),

-- ── First statement ──────────────────────────────────────────────────────────
stmt1 as (
    select
         s.business_id
        ,s.created_at::date              as statement_date
        ,s.payment_due_date::date        as payment_due_date
        ,s.statement_balance  / 100.0    as statement_balance
        ,s.minimum_payment_due / 100.0   as min_payment_due
    from FIVETRAN_DB.PROD_NOVO_API_PUBLIC.CREDIT_CARD_STATEMENTS s
    join booking b on b.business_id = s.business_id
    qualify row_number() over (partition by s.business_id order by s.created_at asc) = 1
),

-- ── Settled payments in the on-time window: statement date → due date ────────
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

-- ── Settled payments in the late-cure window: day after due date → DPD 13 ────
late_pmts as (
    select
         p.business_id
        ,sum(p.amount) / 100.0      as total_paid
        ,min(p.created_at::date)    as first_late_pmt_date
    from FIVETRAN_DB.PROD_NOVO_API_PUBLIC.CREDIT_CARD_PAYMENTS p
    join stmt1 s1
        on  s1.business_id     = p.business_id
        and p.created_at::date >  s1.payment_due_date
        and p.created_at::date <  dateadd(day, 14, s1.payment_due_date)
    where p.status = 'settled'
    group by 1
)

-- Per due date: missed-FP accounts and how many have paid so far,
-- regardless of whether the 14-day cure window has closed
select
     s1.payment_due_date
    ,datediff('day', s1.payment_due_date, current_date())   as days_past_due_so_far

    ,count(distinct b.business_id)                          as missed_fp_accounts

    ,count(distinct case when coalesce(lp.total_paid, 0) >= s1.min_payment_due
                    then b.business_id end)                 as paid_min_or_more_so_far

    ,count(distinct case when coalesce(lp.total_paid, 0) > 0
                          and coalesce(lp.total_paid, 0) < s1.min_payment_due
                    then b.business_id end)                 as paid_partial_so_far

from booking b
join stmt1 s1
    on  s1.business_id = b.business_id
    and s1.payment_due_date < current_date()        -- baked: due date has passed
left join pmts      p   on  p.business_id  = b.business_id
left join late_pmts lp  on  lp.business_id = b.business_id

where b.risk_bucket = 'Reject Inference'            -- swap to '1'..'5' for other buckets
  and s1.statement_balance > 0                      -- owed something at stmt1
  and coalesce(p.total_paid, 0) = 0                 -- missed FP: nothing paid by due date

group by 1, 2
order by 1
;