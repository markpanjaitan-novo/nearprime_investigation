---------------------------CC------------------------------
------CREDIT CARD - MAY 2026 MONTHLY METRICS-----------
-- Verified against Snowflake 2026-06-05
-- All amounts in dollars (cents divided by 100)
-- Test group excluded: business_group_id = '75fe98d2-6549-46a1-aa04-a1c621e21d9e'


-- ============================================================
-- 1. # of accounts with a bankruptcy filed in May 2026
-- ============================================================
-- Result: 0 accounts in May 2026 (1 all-time, not in May)
-- Source: CREDIT_CARD_CLOSE_ACCOUNT_REQUESTS.reason = 'Bankruptcy'
-- Cross-checked: CREDIT_CARD_ACCOUNT_TAG_MAPPINGS.bankruptcy_condition_id also 0 for May 2026
select
 count(distinct business_id) as bankruptcy_acct_count
from FIVETRAN_DB.PROD_NOVO_API_PUBLIC.CREDIT_CARD_CLOSE_ACCOUNT_REQUESTS
where reason = 'Bankruptcy'
and to_char(created_at, 'YYYY-MM') = '2026-05'
and business_id not in (
    select business_id
    from FIVETRAN_DB.PROD_NOVO_API_PUBLIC.BUSINESS_GROUP_ASSIGNMENTS
    where business_group_id = '75fe98d2-6549-46a1-aa04-a1c621e21d9e'
)
;
-- May 2026 result: 0


-- ============================================================
-- 2. % Net Charge-Off Rate in May 2026
-- ============================================================
-- Monthly NCO Rate = Gross Charge-Off Principal / Avg Outstanding Balance
-- Annualized = monthly rate * 12
-- Charge-off recognized at days_past_due 180-210 at month-end statement
-- Result: gross_chargeoff=$26,523, 21 accts, monthly NCO=0.33%, annualized=3.93%
with loan_tape_updated as (
select
 a.*
,b.business_id
,row_number() over (partition by b.business_id, a.statement_date order by a.record_version desc) as rn
from PROD_DB.DATA.CREDIT_CARD_ACCOUNT_LOAN_TAPE_HISTORY a
left join FIVETRAN_DB.PROD_NOVO_API_PUBLIC.CREDIT_CARD_ACCOUNTS b
on a.account_id = b.external_account_id
where b.business_id not in (
    select business_id
    from FIVETRAN_DB.PROD_NOVO_API_PUBLIC.BUSINESS_GROUP_ASSIGNMENTS
    where business_group_id = '75fe98d2-6549-46a1-aa04-a1c621e21d9e'
)
and a.billing_period_number >= 1
),
monthly_balance_raw as (
select
 to_char(statement_date, 'YYYY-MM') as report_mth
,round(sum(case when days_past_due <= 210 then ending_balance end) / 100, 2) as ending_balance
from (select * from loan_tape_updated where rn = 1)
where statement_date in (select last_day(statement_date) from loan_tape_updated where rn = 1)
group by 1
),
monthly_balance as (
select
 report_mth
,ending_balance
,lag(ending_balance) over (order by report_mth) as beginning_balance
from monthly_balance_raw
),
chargeoff as (
select
 to_char(statement_date, 'YYYY-MM') as report_mth
,round(sum(case when days_past_due between 180 and 210
    then (next_due_principal + past_statements_principal + due_principal + past_due_principal) / 100
    end), 2) as gross_chargeoff
,count(distinct case when days_past_due between 180 and 210 then business_id end) as co_acct_count
from (select * from loan_tape_updated where rn = 1)
where statement_date in (select last_day(statement_date) from loan_tape_updated where rn = 1)
group by 1
)
select
 a.report_mth
,a.gross_chargeoff
,a.co_acct_count
,b.beginning_balance
,b.ending_balance
,round((b.beginning_balance + b.ending_balance) / 2, 2) as avg_outstanding_balance
,round(a.gross_chargeoff / nullifzero((b.beginning_balance + b.ending_balance) / 2), 4) as monthly_nco_rate
,round(a.gross_chargeoff / nullifzero((b.beginning_balance + b.ending_balance) / 2) * 12, 4) as annualized_nco_rate
from chargeoff a
left join monthly_balance b
on a.report_mth = b.report_mth
where a.report_mth = '2026-05'
;
-- May 2026 result: gross_chargeoff=$26,523.08, 21 accounts, avg_balance=$8,096,207, monthly=0.33%, annualized=3.93%


-- ============================================================
-- 3. % Repayment Rate (% of customers paying balance in full) in May 2026
-- ============================================================
-- Denominator: accounts with a non-zero statement balance due in May 2026
-- Numerator: accounts where total payments >= statement balance before due date
-- Result: 4,564 accounts with balance due, 1,635 paid in full, 35.82% repayment rate
with statements as (
select
 cs.business_id
,cs.statement_balance / 100 as statement_balance
,cs.end_date
,cs.payment_due_date
,coalesce(sum(cp.amount / 100), 0) as total_payments_made
from FIVETRAN_DB.PROD_NOVO_API_PUBLIC.CREDIT_CARD_STATEMENTS cs
left join FIVETRAN_DB.PROD_NOVO_API_PUBLIC.CREDIT_CARD_PAYMENTS cp
on cs.business_id = cp.business_id
and cp.created_at::date > cs.end_date::date
and cp.created_at::date <= cs.payment_due_date::date
and cp.amount > 0
where cs.business_id not in (
    select business_id
    from FIVETRAN_DB.PROD_NOVO_API_PUBLIC.BUSINESS_GROUP_ASSIGNMENTS
    where business_group_id = '75fe98d2-6549-46a1-aa04-a1c621e21d9e'
)
and to_char(cs.payment_due_date, 'YYYY-MM') = '2026-05'
and cs.statement_balance > 0
group by 1, 2, 3, 4
)
select
 count(distinct business_id) as accts_with_balance_due
,count(distinct case when total_payments_made >= statement_balance then business_id end) as paid_in_full_count
,round(
    count(distinct case when total_payments_made >= statement_balance then business_id end)
    / nullifzero(count(distinct business_id)),
    4
) as repayment_rate
from statements
;
-- May 2026 result: 4,564 accounts with balance, 1,635 paid in full, repayment_rate=35.82%


-- ============================================================
-- 4. % of total chargeback transactions of all card transactions in May 2026
-- 5. $ Total chargeback amount of all card transactions in May 2026
-- ============================================================
-- Chargebacks = entries in CREDIT_CARD_TRANSACTION_DISPUTES (all type='customer')
-- Denominator = settled transactions (result='APPROVED', status='settled')
-- Note: two approaches below:
--   A) Disputes table: captures # of dispute records filed in May 2026 (89 disputes, $15,951 disputed)
--   B) Settlement report: captures $ that cleared the network as chargebacks in May 2026 ($8,282 settled)
--   Use A for count/rate; use B for dollar amount that actually settled

-- 4A + 5A: via CREDIT_CARD_TRANSACTION_DISPUTES (dispute count and filed amounts)
-- Result: 50,729 settled txns, 89 disputes filed, $15,950.80 disputed, 0.1754% chargeback rate
with disputes as (
select
 count(*) as dispute_count
,round(sum(amount) / 100, 2) as total_disputed_amount
from FIVETRAN_DB.PROD_NOVO_API_PUBLIC.CREDIT_CARD_TRANSACTION_DISPUTES
where to_char(created_at, 'YYYY-MM') = '2026-05'
and business_id not in (
    select business_id
    from FIVETRAN_DB.PROD_NOVO_API_PUBLIC.BUSINESS_GROUP_ASSIGNMENTS
    where business_group_id = '75fe98d2-6549-46a1-aa04-a1c621e21d9e'
)
),
all_txns as (
select
 count(*) as total_txn_count
,round(sum(settled_amount) / 100, 2) as total_settled_amount
from FIVETRAN_DB.PROD_NOVO_API_PUBLIC.CREDIT_CARD_TRANSACTIONS
where to_char(created_at, 'YYYY-MM') = '2026-05'
and business_id not in (
    select business_id
    from FIVETRAN_DB.PROD_NOVO_API_PUBLIC.BUSINESS_GROUP_ASSIGNMENTS
    where business_group_id = '75fe98d2-6549-46a1-aa04-a1c621e21d9e'
)
and result = 'APPROVED'
and status = 'settled'
)
select
 a.total_txn_count
,a.total_settled_amount
,b.dispute_count
,b.total_disputed_amount
,round(b.dispute_count / nullifzero(a.total_txn_count), 6) as chargeback_pct_of_txns
from all_txns a
cross join disputes b
;
-- May 2026 result: 50,729 settled txns, $4,502,827 volume, 89 disputes, $15,950.80 disputed, 0.1754%

-- 5B: via CREDIT_CARD_NOVO_SETTLEMENT_REPORT_ITEMS (amount that cleared settlement network)
-- Result: 27 accounts with settled chargebacks, $8,282.17 cleared through network
select
 count(case when sri.disputes_gross_amount != 0 then 1 end) as accounts_with_settled_chargebacks
,round(sum(abs(sri.disputes_gross_amount)) / 100, 2) as total_settled_chargeback_amount
from FIVETRAN_DB.PROD_NOVO_API_PUBLIC.CREDIT_CARD_NOVO_SETTLEMENT_REPORT_ITEMS sri
left join FIVETRAN_DB.PROD_NOVO_API_PUBLIC.CREDIT_CARD_ACCOUNTS ca
on sri.credit_card_account_id = ca.id
where to_char(sri.report_date, 'YYYY-MM') = '2026-05'
and ca.business_id not in (
    select business_id
    from FIVETRAN_DB.PROD_NOVO_API_PUBLIC.BUSINESS_GROUP_ASSIGNMENTS
    where business_group_id = '75fe98d2-6549-46a1-aa04-a1c621e21d9e'
)
;
-- May 2026 result: 27 accounts, $8,282.17 settled chargeback amount


-- ============================================================
-- 6. # Total monthly active credit cards on file at end of May 2026
-- ============================================================
-- Active = accounts not yet charged off (days_past_due < 180) at month-end statement
-- Result: 7,402 total active, 6,978 current, 424 delinquent-but-not-charged-off
with loan_tape_updated as (
select
 a.*
,b.business_id
,row_number() over (partition by b.business_id, a.statement_date order by a.record_version desc) as rn
from PROD_DB.DATA.CREDIT_CARD_ACCOUNT_LOAN_TAPE_HISTORY a
left join FIVETRAN_DB.PROD_NOVO_API_PUBLIC.CREDIT_CARD_ACCOUNTS b
on a.account_id = b.external_account_id
where b.business_id not in (
    select business_id
    from FIVETRAN_DB.PROD_NOVO_API_PUBLIC.BUSINESS_GROUP_ASSIGNMENTS
    where business_group_id = '75fe98d2-6549-46a1-aa04-a1c621e21d9e'
)
and a.billing_period_number >= 1
)
select
 to_char(statement_date, 'YYYY-MM') as report_mth
,count(distinct case when days_past_due < 180 then business_id end) as total_active_cards
,count(distinct case when days_past_due = 0 then business_id end) as current_cards
,count(distinct case when days_past_due between 1 and 179 then business_id end) as delinquent_not_co_cards
from (select * from loan_tape_updated where rn = 1)
where statement_date in (select last_day(statement_date) from loan_tape_updated where rn = 1)
and to_char(statement_date, 'YYYY-MM') = '2026-05'
group by 1
;
-- May 2026 result: 7,402 total active cards (6,978 current + 424 delinquent-not-CO)


-- ============================================================
-- Autopay Enrollment by Month (point-in-time, all months)
-- ============================================================
-- Point-in-time rule: account was enrolled in month M if
--   created_at <= last_day(M)                  -- instruction existed
--   AND (status = 'active'                     -- still active today
--        OR updated_at > last_day(M))           -- cancelled after month M ended
--
-- Autopay launched Oct 2024; data starts there.
-- No business ever has >1 active instruction simultaneously.
-- ============================================================
with month_spine as (
    select
         to_char(dateadd(month, seq4(), '2024-10-01'::date), 'YYYY-MM')         as report_mth
        ,last_day(dateadd(month, seq4(), '2024-10-01'::date))                    as month_end
    from table(generator(rowcount => 36))
    where dateadd(month, seq4(), '2024-10-01'::date) < date_trunc('month', current_date)
),
autopay as (
    select *
    from FIVETRAN_DB.PROD_NOVO_API_PUBLIC.CREDIT_CARD_AUTOPAY_INSTRUCTIONS
    where business_id not in (
        select business_id
        from FIVETRAN_DB.PROD_NOVO_API_PUBLIC.BUSINESS_GROUP_ASSIGNMENTS
        where business_group_id = '75fe98d2-6549-46a1-aa04-a1c621e21d9e'
    )
)
select
     m.report_mth
    ,count(distinct ap.business_id)                                               as enrolled_total
    ,count(distinct case when ap.type = 'statement_balance' then ap.business_id end) as enrolled_pay_in_full
    ,count(distinct case when ap.type = 'minimum_due'       then ap.business_id end) as enrolled_minimum_due
    ,count(distinct case when ap.type = 'fixed_amount'      then ap.business_id end) as enrolled_fixed_amount
from month_spine m
left join autopay ap
    on  ap.created_at::date <= m.month_end
    and (ap.status = 'active' or ap.updated_at::date > m.month_end)
group by 1
order by 1
;


-- ============================================================
-- Application IDs: Apr 2026 – May 27 2026
-- ============================================================
select
     a.id                                                                         as application_id
    ,a.business_id
    ,a.status
    ,to_char(a.created_at, 'YYYY-MM-DD')                                          as applied_at
    ,d.decision
    ,to_char(d.created_at, 'YYYY-MM-DD')                                          as decision_at
from FIVETRAN_DB.PROD_NOVO_API_PUBLIC.CREDIT_CARD_APPLICATIONS a
left join FIVETRAN_DB.PROD_NOVO_API_PUBLIC.CREDIT_CARD_APPLICATION_DECISIONS d
    on d.application_id = a.id
where a.created_at >= '2026-04-01'
  and a.created_at <  '2026-05-28'
  and a.business_id not in (
      select business_id
      from FIVETRAN_DB.PROD_NOVO_API_PUBLIC.BUSINESS_GROUP_ASSIGNMENTS
      where business_group_id = '75fe98d2-6549-46a1-aa04-a1c621e21d9e'
  )
order by a.created_at
;


-- ============================================================
-- Cure Rate: Apr 2026 delinquents that became current in May 2026
-- ============================================================
-- Delinquent in Apr = DPD between 1 and 179 at last_day(Apr 2026)
-- Cured in May     = same account at DPD = 0 at last_day(May 2026)
-- Charged off      = DPD >= 180 at last_day(May 2026) — not a cure
-- ============================================================
with loan_tape_updated as (
    select
         a.*
        ,b.business_id
        ,row_number() over (partition by b.business_id, a.statement_date order by a.record_version desc) as rn
    from PROD_DB.DATA.CREDIT_CARD_ACCOUNT_LOAN_TAPE_HISTORY a
    left join FIVETRAN_DB.PROD_NOVO_API_PUBLIC.CREDIT_CARD_ACCOUNTS b
        on a.account_id = b.external_account_id
    where b.business_id not in (
        select business_id
        from FIVETRAN_DB.PROD_NOVO_API_PUBLIC.BUSINESS_GROUP_ASSIGNMENTS
        where business_group_id = '75fe98d2-6549-46a1-aa04-a1c621e21d9e'
    )
    and a.billing_period_number >= 1
),
apr_delinquent as (
    select
         business_id
        ,days_past_due as apr_dpd
    from (select * from loan_tape_updated where rn = 1)
    where statement_date = last_day('2026-04-01'::date)
      and days_past_due between 1 and 179
),
may_status as (
    select
         business_id
        ,days_past_due as may_dpd
    from (select * from loan_tape_updated where rn = 1)
    where statement_date = last_day('2026-05-01'::date)
)
select
     count(distinct a.business_id)                                                as apr_delinquent_accts
    ,count(distinct case when m.may_dpd = 0          then a.business_id end)      as cured_to_current
    ,count(distinct case when m.may_dpd between 1 and 179 then a.business_id end) as still_delinquent
    ,count(distinct case when m.may_dpd >= 180        then a.business_id end)      as rolled_to_chargeoff
    ,count(distinct case when m.business_id is null   then a.business_id end)      as closed_or_missing
    ,round(
        count(distinct case when m.may_dpd = 0 then a.business_id end)
        / nullifzero(count(distinct a.business_id))
    , 4)                                                                           as cure_rate
from apr_delinquent a
left join may_status m on a.business_id = m.business_id
;


-- ============================================================
-- Monthly rewards: accrued, redeemed, standing balance EOM
-- ============================================================
-- Accrual  : CREDIT_CARD_TRANSACTION_REWARD_ITEMS.created_at
-- Redeemed : CREDIT_CARD_REWARD_REDEMPTIONS.posted_at
-- Balance  : running sum(accrued - redeemed) — portfolio-level
-- All amounts in dollars
-- ============================================================
with ff_excl as (
    select business_id
    from FIVETRAN_DB.PROD_NOVO_API_PUBLIC.BUSINESS_GROUP_ASSIGNMENTS
    where business_group_id = '75fe98d2-6549-46a1-aa04-a1c621e21d9e'
),

monthly_accrual as (
    select
         to_char(ri.created_at, 'YYYY-MM')          as report_mth
        ,round(sum(ri.rewards * -1) / 100.0, 2)     as accrued_dollars
    from FIVETRAN_DB.PROD_NOVO_API_PUBLIC.CREDIT_CARD_TRANSACTION_REWARD_ITEMS ri
    join FIVETRAN_DB.PROD_NOVO_API_PUBLIC.CREDIT_CARD_ACCOUNTS a
        on a.id = ri.credit_card_account_id
    where coalesce(a._fivetran_deleted, false) = false
      and a.business_id not in (select business_id from ff_excl)
    group by 1
),

monthly_redeemed as (
    select
         to_char(r.posted_at, 'YYYY-MM')             as report_mth
        ,round(sum(r.rewards) / 100.0, 2)            as redeemed_dollars
    from FIVETRAN_DB.PROD_NOVO_API_PUBLIC.CREDIT_CARD_REWARD_REDEMPTIONS r
    join FIVETRAN_DB.PROD_NOVO_API_PUBLIC.CREDIT_CARD_ACCOUNTS a
        on a.id = r.credit_card_account_id
    where r.status = 'success'
      and coalesce(a._fivetran_deleted, false) = false
      and a.business_id not in (select business_id from ff_excl)
    group by 1
),

combined as (
    select
         coalesce(ac.report_mth, rd.report_mth)      as report_mth
        ,coalesce(ac.accrued_dollars, 0)              as accrued_dollars
        ,coalesce(rd.redeemed_dollars, 0)             as redeemed_dollars
    from monthly_accrual ac
    full outer join monthly_redeemed rd
        on rd.report_mth = ac.report_mth
)

select
     report_mth
    ,accrued_dollars
    ,redeemed_dollars
    ,round(
        sum(accrued_dollars - redeemed_dollars)
            over (order by report_mth rows between unbounded preceding and current row)
        , 2)                                          as balance_eom
from combined
order by report_mth
;


-- ============================================================
-- Autopay enrollment vs not — active accounts at end of May 2026
-- ============================================================
-- "Active" = had a May 31 month-end statement with DPD < 180
-- (excludes charged-off and closed accounts)
-- Autopay point-in-time: enrolled if instruction existed by May 31
-- and was still active OR cancelled after May 31
-- ============================================================
with ff_excl as (
    select business_id
    from FIVETRAN_DB.PROD_NOVO_API_PUBLIC.BUSINESS_GROUP_ASSIGNMENTS
    where business_group_id = '75fe98d2-6549-46a1-aa04-a1c621e21d9e'
),

active_may as (
    select h.account_id, a.business_id
    from PROD_DB.DATA.CREDIT_CARD_ACCOUNT_LOAN_TAPE_HISTORY h
    join FIVETRAN_DB.PROD_NOVO_API_PUBLIC.CREDIT_CARD_ACCOUNTS a
        on a.external_account_id = h.account_id
    where h.statement_date = '2026-05-31'
      and h.days_past_due < 180
      and h.billing_period_number >= 1
      and a.business_id not in (select business_id from ff_excl)
    qualify row_number() over (partition by h.account_id order by h.record_version desc) = 1
),

autopay_may as (
    select distinct business_id, type
    from FIVETRAN_DB.PROD_NOVO_API_PUBLIC.CREDIT_CARD_AUTOPAY_INSTRUCTIONS
    where created_at::date <= '2026-05-31'
      and (status = 'active' or updated_at::date > '2026-05-31')
      and business_id not in (select business_id from ff_excl)
)

select
     count(distinct am.business_id)                                                     as total_active_accounts
    ,count(distinct ap.business_id)                                                     as enrolled_in_autopay
    ,count(distinct case when ap.business_id is null then am.business_id end)           as not_enrolled
    ,round(count(distinct ap.business_id)
        / nullifzero(count(distinct am.business_id)), 4)                                as enrollment_rate
    ,count(distinct case when ap.type = 'statement_balance' then am.business_id end)   as autopay_pay_in_full
    ,count(distinct case when ap.type = 'minimum_due'       then am.business_id end)   as autopay_minimum_due
    ,count(distinct case when ap.type = 'fixed_amount'      then am.business_id end)   as autopay_fixed_amount
from active_may am
left join autopay_may ap on ap.business_id = am.business_id
;


-- ============================================================
-- Apr 2026 invite-to-booking conversion (booked before May 27)
-- ============================================================
with ff_excl as (
    select business_id
    from FIVETRAN_DB.PROD_NOVO_API_PUBLIC.BUSINESS_GROUP_ASSIGNMENTS
    where business_group_id = '75fe98d2-6549-46a1-aa04-a1c621e21d9e'
),

apr_invites as (
    select distinct business_id
    from FIVETRAN_DB.PROD_NOVO_API_PUBLIC.CREDIT_CARD_INVITATIONS
    where created_at >= '2026-04-01'
      and created_at <  '2026-05-01'
      and business_id not in (select business_id from ff_excl)
),

bookings as (
    select a.business_id, min(d.created_at)::date as booked_date
    from FIVETRAN_DB.PROD_NOVO_API_PUBLIC.CREDIT_CARD_APPLICATIONS a
    join FIVETRAN_DB.PROD_NOVO_API_PUBLIC.CREDIT_CARD_APPLICATION_DECISIONS d
        on d.application_id = a.id
       and d.decision = 'APPROVED'
    where d.created_at < '2026-05-27'
      and a.business_id not in (select business_id from ff_excl)
    group by 1
)

select
     count(distinct i.business_id)                                              as apr_invites_sent
    ,count(distinct b.business_id)                                              as booked_by_may27
    ,count(distinct case when b.business_id is null then i.business_id end)     as did_not_book
    ,round(count(distinct b.business_id)
        / nullifzero(count(distinct i.business_id)), 4)                         as conversion_rate
from apr_invites i
left join bookings b on b.business_id = i.business_id
;


-- ============================================================
-- Applications closed/canceled in May 2026
-- ============================================================
-- There is no explicit 'EXPIRED' status in CREDIT_CARD_APPLICATIONS.
-- CLOSED   = application lapsed with no decision ever made — closest
--            match to "expired" (no row in APPLICATION_DECISIONS)
-- CANCELED = application was actively canceled (likely customer-initiated)
-- Updated_at is used as the date the status changed to CLOSED/CANCELED.
-- ============================================================
select
     to_char(a.updated_at, 'YYYY-MM-DD')                         as closed_date
    ,a.status
    ,count(*)                                                     as application_count
    ,count(distinct a.business_id)                               as distinct_businesses
from FIVETRAN_DB.PROD_NOVO_API_PUBLIC.CREDIT_CARD_APPLICATIONS a
where a.status in ('CLOSED', 'CANCELED')
  and to_char(a.updated_at, 'YYYY-MM') = '2026-05'
  and a.business_id not in (
      select business_id
      from FIVETRAN_DB.PROD_NOVO_API_PUBLIC.BUSINESS_GROUP_ASSIGNMENTS
      where business_group_id = '75fe98d2-6549-46a1-aa04-a1c621e21d9e'
  )
group by 1, 2
order by 1, 2
;


-- ============================================================
-- Average revenue per account — May 2026
-- ============================================================
-- Revenue = interchange + interest collected + fees collected
-- Active accounts: DPD < 180 at May 31
-- ============================================================
with ff_excl as (
    select business_id
    from FIVETRAN_DB.PROD_NOVO_API_PUBLIC.BUSINESS_GROUP_ASSIGNMENTS
    where business_group_id = '75fe98d2-6549-46a1-aa04-a1c621e21d9e'
),

active_may as (
    select
         h.account_id
        ,a.business_id
        ,a.id                                                   as cc_account_id
        ,round(h.payment_allocated_interest / 100.0, 2)        as interest_collected
        ,round(h.payment_allocated_fees     / 100.0, 2)        as fees_collected
    from PROD_DB.DATA.CREDIT_CARD_ACCOUNT_LOAN_TAPE_HISTORY h
    join FIVETRAN_DB.PROD_NOVO_API_PUBLIC.CREDIT_CARD_ACCOUNTS a
        on a.external_account_id = h.account_id
    where h.statement_date = '2026-05-31'
      and h.days_past_due < 180
      and h.billing_period_number >= 1
      and a.business_id not in (select business_id from ff_excl)
    qualify row_number() over (partition by h.account_id order by h.record_version desc) = 1
),

interchange as (
    select
         a.business_id
        ,round(sum(s.interchange_gross_amount * -1 / 100.0), 2) as interchange_dollars
    from active_may a
    left join FIVETRAN_DB.PROD_NOVO_API_PUBLIC.CREDIT_CARD_NOVO_SETTLEMENT_REPORT_ITEMS s
        on  s.credit_card_account_id = a.cc_account_id
        and to_char(s.created_at, 'YYYY-MM') = '2026-05'
    group by 1
),

per_account as (
    select
         a.business_id
        ,coalesce(i.interchange_dollars, 0)                     as interchange
        ,a.interest_collected
        ,a.fees_collected
        ,coalesce(i.interchange_dollars, 0)
            + a.interest_collected
            + a.fees_collected                                   as total_revenue
    from active_may a
    left join interchange i on i.business_id = a.business_id
)

select
     count(*)                                                    as active_accounts
    ,round(sum(interchange),         2)                         as total_interchange
    ,round(sum(interest_collected),  2)                         as total_interest_collected
    ,round(sum(fees_collected),      2)                         as total_fees_collected
    ,round(sum(total_revenue),       2)                         as total_revenue
    ,round(avg(interchange),         2)                         as avg_interchange_per_acct
    ,round(avg(interest_collected),  2)                         as avg_interest_per_acct
    ,round(avg(fees_collected),      2)                         as avg_fees_per_acct
    ,round(avg(total_revenue),       2)                         as avg_revenue_per_acct
from per_account
;
