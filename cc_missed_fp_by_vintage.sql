-- Missed First Payment Rate by Booking Vintage
-- Grain: one row per booking month
-- Missed FP: account had a stmt1 balance > 0 and made no settled payment
--            between the statement date and the payment due date.
-- Fully baked: only accounts whose stmt1 payment due date has passed.
-- Denominator: accounts with a stmt1 balance > 0 (nothing owed → excluded).

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

stmt1 as (
    select
         s.business_id
        ,s.created_at::date              as statement_date
        ,s.payment_due_date::date        as payment_due_date
        ,s.statement_balance  / 100.0    as statement_balance
        ,s.minimum_payment_due / 100.0   as min_payment_due
    from FIVETRAN_DB.PROD_NOVO_API_PUBLIC.CREDIT_CARD_STATEMENTS s
    where s.business_id not in (select business_id from excluded_businesses)
    qualify row_number() over (partition by s.business_id order by s.created_at asc) = 1
),

-- Settled payments in the statement-1 window: issue date → due date
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
)

select
     b.booking_month

    ,count(distinct s1.business_id)                                          as accounts_at_stmt1

    -- Denominator: owed something at stmt1
    ,count(distinct case when s1.statement_balance > 0
                    then s1.business_id end)                                 as stmt1_had_balance

    -- Missed: had a balance, no settled payment by due date
    ,count(distinct case when s1.statement_balance > 0
                          and coalesce(p.total_paid, 0) = 0
                    then s1.business_id end)                                 as missed_fp_count
    ,round(100.0
        * count(distinct case when s1.statement_balance > 0
                               and coalesce(p.total_paid, 0) = 0
                          then s1.business_id end)
        / nullif(count(distinct case when s1.statement_balance > 0
                                then s1.business_id end), 0), 1)            as missed_fp_rate_pct

from stmt1          s1
join  booking       b   on  b.business_id = s1.business_id
left  join pmts     p   on  p.business_id = s1.business_id

where s1.payment_due_date < current_date()

group by 1
order by 1
;