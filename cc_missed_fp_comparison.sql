-- Missed First Payment — Definition Comparison by Risk Bucket
-- Population: accounts booked 2026-03+, grouped by risk_bucket.
-- Scope: statement 1 only.
--
-- Two definitions compared side by side:
--
--  Definition 1 — No payment in window / all accounts at stmt1
--    Denominator: all accounts whose stmt1 due date has passed
--    Numerator:   no settled payment received between statement date and due date
--    Inflated by accounts with $0 balance (nothing owed → trivially "missed").
--
--  Definition 2 — No payment in window / accounts with a balance (recommended)
--    Denominator: accounts with stmt1 statement_balance > 0
--    Numerator:   had a balance AND no settled payment received by the due date
--    Cleaner: only counts people who actually owed money and didn't pay it.

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

acct_dedup as (
    select a.business_id, a.external_account_id,
           row_number() over (partition by a.external_account_id order by a.created_at desc) as rn_dup
    from FIVETRAN_DB.PROD_NOVO_API_PUBLIC.CREDIT_CARD_ACCOUNTS a
    where coalesce(a._fivetran_deleted, false) = false
),

acct as (
    select business_id, external_account_id,
           row_number() over (partition by business_id order by external_account_id) as rn
    from acct_dedup where rn_dup = 1
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
        ,to_char(app.created_at, 'YYYY-MM')           as booking_month
        ,coalesce(rb.risk_bucket, 'Reject Inference') as risk_bucket
    from acct a
    join  app_booking            app on app.business_id = a.business_id
    left join risk_bucket_lookup rb  on rb.business_id  = a.business_id
    where a.rn = 1
      and to_char(app.created_at, 'YYYY-MM') >= '2026-03'
      and a.business_id not in (select business_id from excluded_businesses)
),

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

-- Settled payments received between stmt1 issue date and due date
pmts as (
    select
         p.business_id
        ,sum(p.amount) / 100.0 as total_paid
    from FIVETRAN_DB.PROD_NOVO_API_PUBLIC.CREDIT_CARD_PAYMENTS p
    join stmt1 s1
        on  s1.business_id     = p.business_id
        and p.created_at::date between s1.statement_date and s1.payment_due_date
    where p.status = 'settled'
    group by 1
)

-- Universe for all payment metrics below: accounts with stmt1_balance > 0
-- whose payment due date has already passed.
select
     b.risk_bucket

    ,count(distinct case when s1.payment_due_date < current_date()
                          and s1.statement_balance > 0
                    then b.business_id end)                                 as had_balance

    -- ── Payment outcome breakdown ─────────────────────────────────────────────
    ,sum(case when s1.payment_due_date < current_date()
               and s1.statement_balance > 0
               and coalesce(p.total_paid, 0) = 0
          then 1 else 0 end)                                                as missed_count

    ,sum(case when s1.payment_due_date < current_date()
               and s1.statement_balance > 0
               and coalesce(p.total_paid, 0) > 0
               and coalesce(p.total_paid, 0) < s1.statement_balance * 0.9
          then 1 else 0 end)                                                as partial_count

    ,sum(case when s1.payment_due_date < current_date()
               and s1.statement_balance > 0
               and coalesce(p.total_paid, 0) >= s1.statement_balance * 0.9
          then 1 else 0 end)                                                as paid_in_full_count

    -- ── Rates (denominator = had_balance) ────────────────────────────────────
    ,round(100.0
        * sum(case when s1.payment_due_date < current_date()
                    and s1.statement_balance > 0
                    and coalesce(p.total_paid, 0) = 0
               then 1 else 0 end)
        / nullif(count(distinct case when s1.payment_due_date < current_date()
                                      and s1.statement_balance > 0
                                then b.business_id end), 0), 1)            as missed_pct

    ,round(100.0
        * sum(case when s1.payment_due_date < current_date()
                    and s1.statement_balance > 0
                    and coalesce(p.total_paid, 0) > 0
                    and coalesce(p.total_paid, 0) < s1.statement_balance * 0.9
               then 1 else 0 end)
        / nullif(count(distinct case when s1.payment_due_date < current_date()
                                      and s1.statement_balance > 0
                                then b.business_id end), 0), 1)            as partial_pct

    ,round(100.0
        * sum(case when s1.payment_due_date < current_date()
                    and s1.statement_balance > 0
                    and coalesce(p.total_paid, 0) >= s1.statement_balance * 0.9
               then 1 else 0 end)
        / nullif(count(distinct case when s1.payment_due_date < current_date()
                                      and s1.statement_balance > 0
                                then b.business_id end), 0), 1)            as paid_in_full_pct

from booking    b
left join stmt1 s1 on s1.business_id = b.business_id
left join pmts  p  on p.business_id  = b.business_id

group by 1
order by
    case b.risk_bucket
        when '1' then 1 when '2' then 2 when '3' then 3
        when '4' then 4 when '5' then 5 else 6
    end
;
