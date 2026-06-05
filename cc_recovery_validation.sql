-- ============================================================
-- Recovery Validation Queries
-- Run these in order to verify the chargeoff + recovery flow
-- for a specific account before trusting the aggregate numbers.
-- ============================================================


-- ============================================================
-- STEP 1: Find accounts that charged off AND have post-CO payments
-- Returns a handful of account_ids to spot-check.
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
co_events as (
    select
         account_id
        ,business_id
        ,statement_date                                                            as co_statement_date
        ,to_char(statement_date, 'YYYY-MM')                                       as co_month
        ,round(
            (next_due_principal + past_statements_principal + due_principal + past_due_principal) / 100.0
         , 2)                                                                      as gross_co_amount
    from (select * from loan_tape_updated where rn = 1)
    where days_past_due between 180 and 210
    qualify row_number() over (partition by account_id order by statement_date asc) = 1
)
select
     e.account_id
    ,e.business_id
    ,e.co_month
    ,e.gross_co_amount
    ,round(sum(l.payment_allocated_principal / 100.0), 2)                         as total_recovery_to_date
    ,count(distinct to_char(l.statement_date, 'YYYY-MM'))                         as recovery_months
from co_events e
join (select * from loan_tape_updated where rn = 1) l
    on l.account_id = e.account_id
   and l.statement_date in (select last_day(statement_date) from loan_tape_updated where rn = 1)
   and to_char(l.statement_date, 'YYYY-MM') > e.co_month
   and l.payment_allocated_principal > 0
group by 1, 2, 3, 4
order by total_recovery_to_date desc
limit 20
;


-- ============================================================
-- STEP 2: Statement-by-statement history for a single account
-- Paste an account_id from Step 1 into the WHERE clause.
-- Shows DPD progression, principal balance, and payment fields
-- so you can see the chargeoff event and subsequent payments.
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
)
select
     to_char(statement_date, 'YYYY-MM')                                           as report_mth
    ,statement_date
    ,days_past_due
    ,round(ending_balance / 100.0, 2)                                             as ending_balance
    ,round((next_due_principal + past_statements_principal + due_principal + past_due_principal) / 100.0, 2)
                                                                                  as total_principal
    ,round(payment_allocated_principal / 100.0, 2)                                as payment_allocated_principal
    ,round(payment_allocated_interest  / 100.0, 2)                                as payment_allocated_interest
    ,round(payment_allocated_fees      / 100.0, 2)                                as payment_allocated_fees
    ,case
        when days_past_due between 180 and 210 then '<<< CHARGEOFF'
        when days_past_due > 210              then 'post-CO (>210 DPD)'
        else null
     end                                                                           as flag
from (select * from loan_tape_updated where rn = 1)
where account_id = '<PASTE ACCOUNT_ID FROM STEP 1>'        -- ← swap in account_id
order by statement_date asc
;


-- ============================================================
-- STEP 3: Confirm what the main NACO query counts for that account
-- Verifies the co_month gating and the recovery dollar roll-up.
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
)
select
     e.account_id
    ,e.co_month
    ,e.gross_co_amount
    ,to_char(l.statement_date, 'YYYY-MM')                                         as recovery_month
    ,round(l.payment_allocated_principal / 100.0, 2)                              as recovery_principal
    ,l.days_past_due
from co_events e
join (select * from loan_tape_updated where rn = 1) l
    on l.account_id = e.account_id
   and l.statement_date in (select last_day(statement_date) from loan_tape_updated where rn = 1)
   and to_char(l.statement_date, 'YYYY-MM') > e.co_month
where e.account_id = '<PASTE ACCOUNT_ID FROM STEP 1>'        -- ← swap in account_id
order by l.statement_date asc
;
