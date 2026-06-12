-- ============================================================
-- nearprime_account_investigation.sql
-- Population: FICO 660-719, DPD < 180 at end of May 2026, F&F excluded
-- ============================================================


-- ============================================================
-- QUERY 1: DDA Behavior by Month
--
-- Avg daily balance:   per-account monthly avg of day_end_balance,
--                      then averaged across the cohort
-- Avg monthly inflow:  per-account monthly sum of positive transactions,
--                      then averaged across the cohort
-- Avg monthly outflow: per-account monthly sum of |negative transactions|,
--                      then averaged across the cohort
-- Amounts in dollars (DDA tables are not cents)
-- ============================================================
with population as (
    select cc.business_id
    from FIVETRAN_DB.PROD_NOVO_API_PUBLIC.CREDIT_CARD_ACCOUNTS cc
    join (
        select business_id, fico_score
        from FIVETRAN_DB.PROD_NOVO_API_PUBLIC.CREDIT_CARD_INVITATIONS
        qualify row_number() over (partition by business_id order by created_at desc) = 1
    ) inv on inv.business_id = cc.business_id
    join (
        -- active (not charged off) at end of May 2026
        select b.business_id
        from PROD_DB.DATA.CREDIT_CARD_ACCOUNT_LOAN_TAPE_HISTORY a
        join FIVETRAN_DB.PROD_NOVO_API_PUBLIC.CREDIT_CARD_ACCOUNTS b
            on a.account_id = b.external_account_id
        where a.statement_date = last_day('2026-05-01'::date)
          and a.days_past_due < 180
        qualify row_number() over (partition by b.business_id order by a.record_version desc) = 1
    ) active on active.business_id = cc.business_id
    where inv.fico_score between 660 and 719
      and cc.business_id not in (
          select business_id from FIVETRAN_DB.PROD_NOVO_API_PUBLIC.BUSINESS_GROUP_ASSIGNMENTS
          where business_group_id = '75fe98d2-6549-46a1-aa04-a1c621e21d9e'
      )
),
monthly_balance as (
    select
         p.business_id
        ,to_char(b.date, 'YYYY-MM')        as report_mth
        ,avg(b.day_end_balance)             as avg_daily_balance
    from population p
    join PROD_DB.DATA.BALANCES_DAILY b on b.business_id = p.business_id
    group by 1, 2
),
monthly_txns as (
    select
         p.business_id
        ,to_char(t.created_date, 'YYYY-MM') as report_mth
        ,sum(case when t.amount > 0 then  t.amount  else 0 end) as monthly_inflow
        ,sum(case when t.amount < 0 then -t.amount  else 0 end) as monthly_outflow
    from population p
    join PROD_DB.DATA.TRANSACTIONS t on t.business_id = p.business_id
    where t.status = 'active'
    group by 1, 2
)
select
     coalesce(b.report_mth, t.report_mth)  as report_mth
    ,count(distinct b.business_id)          as accounts_in_cohort
    ,round(avg(b.avg_daily_balance), 2)/100     as avg_daily_balance
    ,round(avg(t.monthly_inflow),  2)/100       as avg_monthly_inflow
    ,round(avg(t.monthly_outflow), 2)/100       as avg_monthly_outflow
from monthly_balance b
full outer join monthly_txns t
    on  b.business_id = t.business_id
    and b.report_mth  = t.report_mth
where coalesce(b.report_mth, t.report_mth) > '2024-11'
  and coalesce(b.report_mth, t.report_mth) < to_char(current_date, 'YYYY-MM')
group by 1
order by 1
;


-- ============================================================
-- QUERY 2: Monthly CC Performance
--
-- NIBT = interchange + interest_collected + fees_collected
--        - reward_accrued - chargeoff_dollar
-- All CC amounts divided by 100 (loan tape is in cents)
-- Interest and fees exclude charged-off accounts (co_flag)
-- ============================================================
with loan_tape_updated as (
    select
         a.*
        ,b.business_id
        ,b.id as cc_account_id
        ,row_number() over (partition by b.business_id, a.statement_date order by a.record_version desc) as rn
    from PROD_DB.DATA.CREDIT_CARD_ACCOUNT_LOAN_TAPE_HISTORY a
    join FIVETRAN_DB.PROD_NOVO_API_PUBLIC.CREDIT_CARD_ACCOUNTS b
        on a.account_id = b.external_account_id
    where b.business_id not in (
        select business_id from FIVETRAN_DB.PROD_NOVO_API_PUBLIC.BUSINESS_GROUP_ASSIGNMENTS
        where business_group_id = '75fe98d2-6549-46a1-aa04-a1c621e21d9e'
    )
    and a.billing_period_number >= 1
),
population as (
    select cc.business_id
    from FIVETRAN_DB.PROD_NOVO_API_PUBLIC.CREDIT_CARD_ACCOUNTS cc
    join (
        select business_id, fico_score
        from FIVETRAN_DB.PROD_NOVO_API_PUBLIC.CREDIT_CARD_INVITATIONS
        qualify row_number() over (partition by business_id order by created_at desc) = 1
    ) inv on inv.business_id = cc.business_id
    join (
        select b.business_id
        from PROD_DB.DATA.CREDIT_CARD_ACCOUNT_LOAN_TAPE_HISTORY a
        join FIVETRAN_DB.PROD_NOVO_API_PUBLIC.CREDIT_CARD_ACCOUNTS b
            on a.account_id = b.external_account_id
        where a.statement_date = last_day('2026-05-01'::date)
          and a.days_past_due < 180
        qualify row_number() over (partition by b.business_id order by a.record_version desc) = 1
    ) active on active.business_id = cc.business_id
    where inv.fico_score between 660 and 719
      and cc.business_id not in (
          select business_id from FIVETRAN_DB.PROD_NOVO_API_PUBLIC.BUSINESS_GROUP_ASSIGNMENTS
          where business_group_id = '75fe98d2-6549-46a1-aa04-a1c621e21d9e'
      )
),
co_account as (
    select distinct account_id
    from PROD_DB.DATA.CREDIT_CARD_ACCOUNT_LOAN_TAPE_HISTORY
    where days_past_due = 181
),
monthly_cc as (
    select
         to_char(l.statement_date, 'YYYY-MM')                                          as report_mth
        ,round(sum(l.ending_balance / 100.0), 2)                                       as ending_balance
        ,round(sum(l.period_purchases / 100.0), 2)                                     as spend
        ,round(sum(case when co.account_id is null then l.payment_allocated_interest / 100.0 else 0 end), 2)
                                                                                        as interest_revenue
        ,round(sum(case when co.account_id is null then l.payment_allocated_fees / 100.0 else 0 end), 2)
                                                                                        as fee_revenue
        ,round(sum(case when l.days_past_due between 180 and 210
                   then (l.next_due_principal + l.past_statements_principal + l.due_principal + l.past_due_principal) / 100.0
                   end), 2)                                                              as chargeoff_dollar
    from (select * from loan_tape_updated where rn = 1) l
    join population p on l.business_id = p.business_id
    left join co_account co on l.account_id = co.account_id
    where l.statement_date in (select last_day(statement_date) from loan_tape_updated where rn = 1)
    group by 1
),
monthly_interchange as (
    select
         to_char(s.created_at, 'YYYY-MM')                                              as report_mth
        ,round(sum(s.interchange_gross_amount * -1 / 100.0), 2)                         as interchange_revenue
    from FIVETRAN_DB.PROD_NOVO_API_PUBLIC.CREDIT_CARD_NOVO_SETTLEMENT_REPORT_ITEMS s
    join FIVETRAN_DB.PROD_NOVO_API_PUBLIC.CREDIT_CARD_ACCOUNTS acc on s.credit_card_account_id = acc.id
    join population p on acc.business_id = p.business_id
    group by 1
),
monthly_rewards as (
    select
         to_char(r.created_at, 'YYYY-MM')                                              as report_mth
        ,round(sum(r.rewards * -1 / 100.0), 2)                                          as reward_accrued
    from FIVETRAN_DB.PROD_NOVO_API_PUBLIC.CREDIT_CARD_TRANSACTION_REWARD_ITEMS r
    join FIVETRAN_DB.PROD_NOVO_API_PUBLIC.CREDIT_CARD_ACCOUNTS acc on r.credit_card_account_id = acc.id
    join population p on acc.business_id = p.business_id
    group by 1
)
select
     c.report_mth
    ,c.ending_balance/100 as ending_balance
    ,c.spend/100 as spend
    ,coalesce(i.interchange_revenue, 0)/100                                                 as interchange_revenue
    ,c.interest_revenue/100 as interest_revenue
    ,c.fee_revenue/100 as fee_revenue
    ,coalesce(r.reward_accrued, 0)/100                                                      as reward_accrued
    ,coalesce(c.chargeoff_dollar, 0)/100                                                    as chargeoff_dollar
    ,round(
        coalesce(i.interchange_revenue, 0)
        + c.interest_revenue
        + c.fee_revenue
        + coalesce(r.reward_accrued, 0)
        - coalesce(c.chargeoff_dollar, 0)
     , 2)/100                                                                                as nibt
from monthly_cc c
left join monthly_interchange i on c.report_mth = i.report_mth
left join monthly_rewards     r on c.report_mth = r.report_mth
where c.report_mth > '2024-11'
  and c.report_mth < to_char(current_date, 'YYYY-MM')
order by 1
;


-- ============================================================
-- Sample FICO 660-719 accounts booked 2024-2025 (active May 2026)
-- Sorted by max_dpd desc — accounts with most delinquency history first
-- Swap any business_id into Queries 3 & 4 below
-- ============================================================
-- BUSINESS_ID                            BOOKING_DATE  FICO  STMT_RECORDS  MAX_DPD
-- 48b37eb2-a433-4c64-aa9d-cd5ab79118f1   2025-05-13    662   390           207  ← charged off
-- 1edcf965-b2c2-4697-bcd2-34ff1ba9581d   2025-06-25    682   347           178  ← near CO
-- 8677ec88-d81b-4ed9-93cf-4b3ac9559391   2024-12-31    665   523           175  ← near CO, long history
-- 3c89c894-5559-4efa-9495-c5ad62381e57   2025-01-28    664   495           175
-- 9a9d544d-20c0-4bf3-b9f9-f7bee7016539   2025-01-28    672   495           175
-- 036fea1d-d7dd-4034-8507-636c834757b0   2025-07-31    684   311           175
-- 0a435ed1-f2a1-485f-a7d0-de79f48868d6   2025-07-06    686   336           169
-- 8f2d2263-377d-47f3-b81d-1484159a0183   2025-04-08    670   425           167
-- cdaf9bc7-035c-4848-923b-83e8072ebf20   2025-04-08    681   425           167
-- 01683b35-cff0-48c8-ab76-9833db28404e   2025-03-11    663   453           164


-- ============================================================
-- QUERY 3: Individual Account — DDA Behavior by Month
--
-- Shows one account's actual monthly DDA activity (not averages).
-- Swap the business_id below to look at a different account.
-- Amounts in dollars (DDA tables are not cents).
-- ============================================================
with acct as (
    select '8677ec88-d81b-4ed9-93cf-4b3ac9559391' as business_id  -- ← swap here
),
monthly_balance as (
    select
         to_char(b.date, 'YYYY-MM')  as report_mth
        ,avg(b.day_end_balance)       as avg_daily_balance
        ,min(b.day_end_balance)       as min_daily_balance
        ,max(b.day_end_balance)       as max_daily_balance
    from acct a
    join PROD_DB.DATA.BALANCES_DAILY b on b.business_id = a.business_id
    group by 1
),
monthly_txns as (
    select
         to_char(t.created_date, 'YYYY-MM')                                        as report_mth
        ,sum(case when t.amount > 0 then  t.amount  else 0 end)                    as total_inflow
        ,sum(case when t.amount < 0 then -t.amount  else 0 end)                    as total_outflow
        ,count(case when t.amount > 0 then 1 end)                                  as inflow_txn_count
        ,count(case when t.amount < 0 then 1 end)                                  as outflow_txn_count
    from acct a
    join PROD_DB.DATA.TRANSACTIONS t on t.business_id = a.business_id
    where t.status = 'active'
    group by 1
)
select
     coalesce(b.report_mth, t.report_mth)   as report_mth
    ,round(b.avg_daily_balance, 2)           as avg_daily_balance
    ,round(b.min_daily_balance, 2)           as min_daily_balance
    ,round(b.max_daily_balance, 2)           as max_daily_balance
    ,round(t.total_inflow,  2)               as total_inflow
    ,round(t.total_outflow, 2)               as total_outflow
    ,t.inflow_txn_count
    ,t.outflow_txn_count
    ,round(t.total_inflow - t.total_outflow, 2) as net_cashflow
from monthly_balance b
full outer join monthly_txns t
    on b.report_mth = t.report_mth
where coalesce(b.report_mth, t.report_mth) > '2024-11'
  and coalesce(b.report_mth, t.report_mth) < to_char(current_date, 'YYYY-MM')
order by 1
;


-- ============================================================
-- QUERY 4: Individual Account — Monthly CC Performance
--
-- Shows one account's actual monthly CC metrics (not averages).
-- Swap the business_id below to look at a different account.
-- All CC amounts divided by 100 (loan tape is in cents).
-- ============================================================
with acct as (
    select '8677ec88-d81b-4ed9-93cf-4b3ac9559391' as business_id  -- ← swap here
),
loan_tape_updated as (
    select
         a.*
        ,b.business_id
        ,b.id as cc_account_id
        ,row_number() over (partition by b.business_id, a.statement_date order by a.record_version desc) as rn
    from PROD_DB.DATA.CREDIT_CARD_ACCOUNT_LOAN_TAPE_HISTORY a
    join FIVETRAN_DB.PROD_NOVO_API_PUBLIC.CREDIT_CARD_ACCOUNTS b
        on a.account_id = b.external_account_id
    join acct on acct.business_id = b.business_id
    where a.billing_period_number >= 1
),
co_account as (
    select distinct account_id
    from PROD_DB.DATA.CREDIT_CARD_ACCOUNT_LOAN_TAPE_HISTORY l
    join acct on acct.business_id = (
        select business_id from FIVETRAN_DB.PROD_NOVO_API_PUBLIC.CREDIT_CARD_ACCOUNTS
        where external_account_id = l.account_id limit 1
    )
    where days_past_due = 181
),
monthly_cc as (
    select
         to_char(l.statement_date, 'YYYY-MM')                                          as report_mth
        ,l.days_past_due
        ,round(l.ending_balance / 100.0, 2)                                            as ending_balance
        ,round(l.credit_limit   / 100.0, 2)                                            as credit_limit
        ,round(l.period_purchases / 100.0, 2)                                          as spend
        ,round(case when co.account_id is null then l.payment_allocated_interest / 100.0 else 0 end, 2)
                                                                                        as interest_revenue
        ,round(case when co.account_id is null then l.payment_allocated_fees / 100.0 else 0 end, 2)
                                                                                        as fee_revenue
        ,round(case when l.days_past_due between 180 and 210
                    then (l.next_due_principal + l.past_statements_principal + l.due_principal + l.past_due_principal) / 100.0
                    else 0 end, 2)                                                      as chargeoff_dollar
    from (select * from loan_tape_updated where rn = 1) l
    left join co_account co on l.account_id = co.account_id
    where l.statement_date in (select last_day(statement_date) from loan_tape_updated where rn = 1)
),
monthly_interchange as (
    select
         to_char(s.created_at, 'YYYY-MM')                                              as report_mth
        ,round(sum(s.interchange_gross_amount * -1 / 100.0), 2)                         as interchange_revenue
    from FIVETRAN_DB.PROD_NOVO_API_PUBLIC.CREDIT_CARD_NOVO_SETTLEMENT_REPORT_ITEMS s
    join FIVETRAN_DB.PROD_NOVO_API_PUBLIC.CREDIT_CARD_ACCOUNTS acc
        on s.credit_card_account_id = acc.id
    join acct on acct.business_id = acc.business_id
    group by 1
),
monthly_rewards as (
    select
         to_char(r.created_at, 'YYYY-MM')                                              as report_mth
        ,round(sum(r.rewards * -1 / 100.0), 2)                                          as reward_accrued
    from FIVETRAN_DB.PROD_NOVO_API_PUBLIC.CREDIT_CARD_TRANSACTION_REWARD_ITEMS r
    join FIVETRAN_DB.PROD_NOVO_API_PUBLIC.CREDIT_CARD_ACCOUNTS acc
        on r.credit_card_account_id = acc.id
    join acct on acct.business_id = acc.business_id
    group by 1
)
select
     c.report_mth
    ,c.days_past_due
    ,c.credit_limit
    ,c.ending_balance
    ,round(c.ending_balance / nullifzero(c.credit_limit), 4)                           as utilization
    ,c.spend
    ,coalesce(i.interchange_revenue, 0)                                                 as interchange_revenue
    ,c.interest_revenue
    ,c.fee_revenue
    ,coalesce(r.reward_accrued, 0)                                                      as reward_accrued
    ,c.chargeoff_dollar
    ,round(
        coalesce(i.interchange_revenue, 0)
        + c.interest_revenue
        + c.fee_revenue
        - coalesce(r.reward_accrued, 0)
        - c.chargeoff_dollar
     , 2)                                                                                as nibt
from monthly_cc c
left join monthly_interchange i on c.report_mth = i.report_mth
left join monthly_rewards     r on c.report_mth = r.report_mth
where c.report_mth > '2024-11'
  and c.report_mth < to_char(current_date, 'YYYY-MM')
order by 1
;
--Invites
with inv as (
    select business_id, fico_score
    from FIVETRAN_DB.PROD_NOVO_API_PUBLIC.CREDIT_CARD_INVITATIONS
    qualify row_number() over (partition by business_id order by created_at desc) = 1
),
booking as (
    select business_id, min(created_at)::date as booking_date
    from FIVETRAN_DB.PROD_NOVO_API_PUBLIC.CREDIT_CARD_APPLICATIONS
    where status = 'APPROVED'
    group by 1
),
active_may as (
    select b.business_id
    from PROD_DB.DATA.CREDIT_CARD_ACCOUNT_LOAN_TAPE_HISTORY a
    join FIVETRAN_DB.PROD_NOVO_API_PUBLIC.CREDIT_CARD_ACCOUNTS b
        on a.account_id = b.external_account_id
    where a.statement_date = last_day('2026-05-01'::date)
      and a.days_past_due < 180
    qualify row_number() over (partition by b.business_id order by a.record_version desc) = 1
),
stmt_count as (
    select
         b.business_id
        ,count(distinct a.statement_date) as stmt_count
        ,max(a.days_past_due)             as max_dpd
    from PROD_DB.DATA.CREDIT_CARD_ACCOUNT_LOAN_TAPE_HISTORY a
    join FIVETRAN_DB.PROD_NOVO_API_PUBLIC.CREDIT_CARD_ACCOUNTS b
        on a.account_id = b.external_account_id
    where a.billing_period_number >= 1
    group by 1
)
select
     bk.business_id
    ,bk.booking_date
    ,inv.fico_score
    ,sc.stmt_count
    ,sc.max_dpd
from booking bk
join inv        on inv.business_id = bk.business_id
join active_may on active_may.business_id = bk.business_id
join stmt_count sc on sc.business_id = bk.business_id
where inv.fico_score between 660 and 719
  and bk.booking_date between '2024-10-01' and '2025-12-31'
  and bk.business_id not in (
      select business_id from FIVETRAN_DB.PROD_NOVO_API_PUBLIC.BUSINESS_GROUP_ASSIGNMENTS
      where business_group_id = '75fe98d2-6549-46a1-aa04-a1c621e21d9e'
  )
order by sc.max_dpd desc, sc.stmt_count desc
;
