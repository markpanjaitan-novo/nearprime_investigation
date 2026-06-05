-- ============================================================
-- CC Cohort-Matched NACO by Chargeoff Month
--
-- Grain: one row per chargeoff cohort month.
--
-- Gross CO:    principal (4-slice sum) at DPD 180-210, first crossing only,
--              recognised in the month the account entered DPD 180-210.
-- Recovery:    all payment_allocated_principal received from those same accounts
--              in any month strictly after their chargeoff month — cohort-matched,
--              not calendar-month mixed.
-- NACO $:      gross_co - cumulative_recovery (to date)
-- Recovery %:  cumulative_recovery / gross_co
-- NACO rate:   net_co / avg_portfolio_balance in the chargeoff month (annualized x12)
-- Gross rate:  gross_co / avg_portfolio_balance in the chargeoff month (annualized x12)
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
-- One row per account: the first month they crossed into DPD 180-210
-- and the gross CO principal recognised at that point.
co_events as (
    select
         account_id
        ,business_id
        ,to_char(statement_date, 'YYYY-MM')                                       as co_month
        ,round(
            (next_due_principal + past_statements_principal + due_principal + past_due_principal) / 100.0
         , 2)                                                                      as gross_co_amount
    from (select * from loan_tape_updated where rn = 1)
    where days_past_due between 180 and 210
    qualify row_number() over (partition by account_id order by statement_date asc) = 1
),
-- For each CO account, sum all principal payments received in months after chargeoff.
post_co_recoveries as (
    select
         e.co_month
        ,round(sum(l.payment_allocated_principal / 100.0), 2)                     as cumulative_recovery_dollar
    from co_events e
    join (select * from loan_tape_updated where rn = 1) l
        on l.account_id = e.account_id
       and l.statement_date in (select last_day(statement_date) from loan_tape_updated where rn = 1)
       and to_char(l.statement_date, 'YYYY-MM') > e.co_month
    group by 1
),
-- Portfolio ending balance by month for the rate denominator.
-- Uses sum(ending_balance) across all accounts at month-end — no DPD cap,
-- matching the outstanding_balance definition in the portfolio snapshot query.
monthly_balance_raw as (
    select
         to_char(statement_date, 'YYYY-MM')                                       as report_mth
        ,round(sum(ending_balance / 100.0), 2)                                    as ending_balance
    from (select * from loan_tape_updated where rn = 1)
    where statement_date in (select last_day(statement_date) from loan_tape_updated where rn = 1)
    group by 1
),
monthly_balance as (
    select
         report_mth
        ,ending_balance
        ,lag(ending_balance) over (order by report_mth)                           as beginning_balance
    from monthly_balance_raw
),
-- Cohort-level gross CO summary
co_cohort as (
    select
         co_month
        ,count(distinct account_id)                                               as co_acct_count
        ,round(sum(gross_co_amount), 2)                                           as gross_co_dollar
    from co_events
    group by 1
)
select
     c.co_month
    ,c.co_acct_count
    ,c.gross_co_dollar
    ,coalesce(r.cumulative_recovery_dollar, 0)                                    as cumulative_recovery_dollar
    ,round(c.gross_co_dollar - coalesce(r.cumulative_recovery_dollar, 0), 2)      as net_co_dollar
    -- Recovery % of gross written off
    ,round(coalesce(r.cumulative_recovery_dollar, 0) / nullifzero(c.gross_co_dollar), 4)
                                                                                  as recovery_pct
    ,round(mb.avg_portfolio_balance, 2)                                           as avg_portfolio_balance
    -- Gross CO rate (monthly and annualized)
    ,round(c.gross_co_dollar / nullifzero(mb.avg_portfolio_balance), 4)           as gross_co_rate_monthly
    ,round(c.gross_co_dollar / nullifzero(mb.avg_portfolio_balance) * 12, 4)      as gross_co_rate_annualized
    -- NACO rate: net of cohort-matched recoveries (monthly and annualized)
    ,round((c.gross_co_dollar - coalesce(r.cumulative_recovery_dollar, 0)) / nullifzero(mb.avg_portfolio_balance), 4)
                                                                                  as naco_rate_monthly
    ,round((c.gross_co_dollar - coalesce(r.cumulative_recovery_dollar, 0)) / nullifzero(mb.avg_portfolio_balance) * 12, 4)
                                                                                  as naco_rate_annualized
from co_cohort c
left join post_co_recoveries r
    on c.co_month = r.co_month
left join (
    select report_mth, round((beginning_balance + ending_balance) / 2, 2) as avg_portfolio_balance
    from monthly_balance
)  mb on c.co_month = mb.report_mth
where c.co_month > '2024-11'
  and c.co_month < to_char(current_date, 'YYYY-MM')
order by 1
;
