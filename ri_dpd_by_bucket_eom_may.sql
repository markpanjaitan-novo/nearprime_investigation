-- DPD distribution by risk bucket — end of May 2026 snapshot
-- Rows: DPD buckets (Current, DQ 1-29, 30-59, ...). Columns: risk buckets 1-5 + RI.
--
-- Population: accounts booked 2026-03 → 2026-05 (new account model era, F&F
-- excluded). June bookings can't appear in a May snapshot.
-- Snapshot: loan tape rows at statement_date = 2026-06-01 (state as of end of
-- May, per the calendar-month pattern), deduped per account by record_version.
-- 'Not on loan tape' row catches booked accounts with no snapshot row so each
-- column sums to that bucket's total booked.

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

-- ── Account universe (booked 2026-03 → 2026-05, F&F excluded) ────────────────
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
        ,coalesce(rb.risk_bucket, 'Reject Inference')    as risk_bucket
    from acct a
    join  app_booking           app on app.business_id = a.business_id
    left join risk_bucket_lookup rb  on rb.business_id  = a.business_id
    where a.rn = 1
      and to_char(app.created_at, 'YYYY-MM') between '2026-03' and '2026-05'
      and a.business_id not in (select business_id from excluded_businesses)
),

-- ── End-of-May snapshot: tape row dated June 1, latest record version ────────
eom_tape as (
    select
         b.business_id
        ,lt.days_past_due
        ,lt.ending_balance / 100.0  as ending_balance
    from PROD_DB.DATA.CREDIT_CARD_ACCOUNT_LOAN_TAPE_HISTORY lt
    join booking b on b.external_account_id = lt.account_id
    where lt.statement_date::date = '2026-06-01'
    qualify row_number() over (
        partition by b.business_id
        order by lt.record_version desc
    ) = 1
),

classified as (
    select
         b.risk_bucket
        ,case
            when t.business_id is null          then '7. Not on loan tape'
            when t.days_past_due = 0            then '1. Current'
            when t.days_past_due between 1   and 29  then '2. DQ 1-29'
            when t.days_past_due between 30  and 59  then '3. DQ 30-59'
            when t.days_past_due between 60  and 89  then '4. DQ 60-89'
            when t.days_past_due between 90  and 179 then '5. DQ 90-179'
            else                                     '6. DQ 180+'
         end as dpd_bucket
    from booking b
    left join eom_tape t on t.business_id = b.business_id
)

select
     dpd_bucket
    ,count(case when risk_bucket = '1' then 1 end)                  as bucket_1
    ,count(case when risk_bucket = '2' then 1 end)                  as bucket_2
    ,count(case when risk_bucket = '3' then 1 end)                  as bucket_3
    ,count(case when risk_bucket = '4' then 1 end)                  as bucket_4
    ,count(case when risk_bucket = '5' then 1 end)                  as bucket_5
    ,count(case when risk_bucket = 'Reject Inference' then 1 end)   as reject_inference
    ,count(*)                                                       as total
from classified
group by 1
order by 1
;