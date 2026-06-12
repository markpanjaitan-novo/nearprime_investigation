-- AR (principal balance) distribution — end of reporting month May 2026
-- Three result blocks, run each independently:
--   1. AR by risk bucket
--   2. AR by booking vintage
--   3. DPD 30-59 AR split by risk bucket × booking vintage
--
-- Population: ALL booked accounts (2024-11 →), F&F excluded — delinquent AR
-- lives in older vintages, so this is portfolio-wide, unlike the 2026-03+
-- reject inference queries.
-- Snapshot: aligned to the monitoring dashboard's EOM definition
-- (11_statement_spine.sql): loan tape rows whose statement_date IS the
-- calendar last day of the month (2026-05-31 for report month May), with
-- billing_period_number >= 1, deduped per account by record_version.
-- AR = principal_balance > 0 at the snapshot (credit balances excluded).
-- Principal balance = next_due_principal + past_statements_principal +
--   due_principal + past_due_principal — matches dashboard's principal_balance_dollars.
-- Bucket label: scored buckets 1-5 from the lookup; 'Reject Inference' only
-- for 2026-03+ bookings missing scores; earlier unscored bookings are
-- 'Legacy Unscored' so RI keeps its meaning.

-- ── Block 1: AR by risk bucket ───────────────────────────────────────────────
with excluded_businesses as (
    select business_id
    from PROD_DB.DBT_OUTPUT.BUSINESS_GROUP_ASSIGNMENTS
    where business_group_id = '75fe98d2-6549-46a1-aa04-a1c621e21d9e'
),

latest_invite as (
    select business_id, max(created_at) as last_invite_at
    from FIVETRAN_DB.PROD_NOVO_API_PUBLIC.CREDIT_CARD_INVITATIONS
    group by 1
),

risk_bucket_lookup as (
    select
         b.business_id
        ,case
            when to_char(li.last_invite_at, 'YYYY-MM') = '2026-04'
                then coalesce(apr.final_risk_bucket::text, retro.final_risk_bucket::text)
            when to_char(li.last_invite_at, 'YYYY-MM') = '2026-05'
                then coalesce(may."final_risk_bucket"::text, apr.final_risk_bucket::text)
            else retro.final_risk_bucket::text
         end as risk_bucket
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
        ,to_char(app.created_at, 'YYYY-MM')              as booking_month
        ,case
            when rb.risk_bucket is not null              then rb.risk_bucket
            when to_char(app.created_at, 'YYYY-MM') >= '2026-03' then 'Reject Inference'
            else 'Legacy Unscored'
         end                                             as risk_bucket
    from acct a
    join  app_booking           app on app.business_id = a.business_id
    left join risk_bucket_lookup rb  on rb.business_id  = a.business_id
    where a.rn = 1
      and a.business_id not in (select business_id from excluded_businesses)
),

eom_tape as (
    select
         b.business_id
        ,b.booking_month
        ,b.risk_bucket
        ,lt.days_past_due
        ,(
            coalesce(lt.next_due_principal,        0)
          + coalesce(lt.past_statements_principal, 0)
          + coalesce(lt.due_principal,             0)
          + coalesce(lt.past_due_principal,        0)
         ) / 100.0  as principal_balance
    from PROD_DB.DATA.CREDIT_CARD_ACCOUNT_LOAN_TAPE_HISTORY lt
    join booking b on b.external_account_id = lt.account_id
    where lt.statement_date::date = '2026-05-31'   -- last day of report month, per dashboard spine
      and lt.billing_period_number >= 1
    qualify row_number() over (
        partition by b.business_id
        order by lt.record_version desc
    ) = 1
)

select
     risk_bucket
    ,count(case when principal_balance > 0 then 1 end)              as accounts_with_balance
    ,round(sum(case when principal_balance > 0
               then principal_balance end), 0)                      as total_ar
    ,round(100.0 * sum(case when principal_balance > 0 then principal_balance end)
        / nullif(sum(sum(case when principal_balance > 0 then principal_balance end)) over (), 0), 1)
                                                                     as pct_of_ar
    ,round(sum(case when days_past_due = 0
                     and principal_balance > 0 then principal_balance end), 0)  as current_ar
    ,round(sum(case when days_past_due between 1 and 29
                     and principal_balance > 0 then principal_balance end), 0)  as dq1_30_ar
    ,round(sum(case when days_past_due between 30 and 59
                     and principal_balance > 0 then principal_balance end), 0)  as dq30_60_ar
    ,round(sum(case when days_past_due between 60 and 89
                     and principal_balance > 0 then principal_balance end), 0)  as dq60_90_ar
    ,round(sum(case when days_past_due between 90 and 179
                     and principal_balance > 0 then principal_balance end), 0)  as dq90_180_ar
    ,round(sum(case when days_past_due >= 180
                     and principal_balance > 0 then principal_balance end), 0)  as dq180_plus_ar
from eom_tape
group by 1
order by
    case risk_bucket
        when '1' then 1 when '2' then 2 when '3' then 3
        when '4' then 4 when '5' then 5
        when 'Reject Inference' then 6 else 7
    end
;


-- ── Block 2: AR by booking vintage ───────────────────────────────────────────
-- (re-run the CTE chain above, replacing the final select with:)
/*
select
     booking_month
    ,count(case when principal_balance > 0 then 1 end)              as accounts_with_balance
    ,round(sum(case when principal_balance > 0
               then principal_balance end), 0)                      as total_ar
    ,round(100.0 * sum(case when principal_balance > 0 then principal_balance end)
        / nullif(sum(sum(case when principal_balance > 0 then principal_balance end)) over (), 0), 1)
                                                                     as pct_of_ar
    ,round(sum(case when days_past_due = 0
                     and principal_balance > 0 then principal_balance end), 0)  as current_ar
    ,round(sum(case when days_past_due between 1 and 29
                     and principal_balance > 0 then principal_balance end), 0)  as dq1_30_ar
    ,round(sum(case when days_past_due between 30 and 59
                     and principal_balance > 0 then principal_balance end), 0)  as dq30_60_ar
    ,round(sum(case when days_past_due between 60 and 89
                     and principal_balance > 0 then principal_balance end), 0)  as dq60_90_ar
    ,round(sum(case when days_past_due between 90 and 179
                     and principal_balance > 0 then principal_balance end), 0)  as dq90_180_ar
    ,round(sum(case when days_past_due >= 180
                     and principal_balance > 0 then principal_balance end), 0)  as dq180_plus_ar
from eom_tape
group by 1
order by 1
;
*/


-- ── Block 3: DPD 30-59 AR by risk bucket × booking vintage ───────────────────
-- (re-run the CTE chain above, replacing the final select with:)
/*
select
     booking_month
    ,risk_bucket
    ,count(*)                                                    as dq30_59_accounts
    ,round(sum(principal_balance), 0)                            as dq30_59_ar
from eom_tape
where days_past_due between 30 and 59
  and principal_balance > 0
group by 1, 2
order by 1, 2
;
*/