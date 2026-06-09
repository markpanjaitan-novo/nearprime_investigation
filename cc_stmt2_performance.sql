-- Statement 2 Performance Monitor
-- Grain: one row per booking-month cohort
-- Scope: accounts booked 2024-11 onwards with a second billing statement on file
-- Payment metrics: measured over the statement-1 payment window (issue date → due date)
-- Autopay enrollment: point-in-time as of statement-2 date
-- Activation: any purchase in billing period 1 or 2

with excluded_businesses as (
    select business_id
    from FIVETRAN_DB.PROD_NOVO_API_PUBLIC.BUSINESS_GROUP_ASSIGNMENTS
    where business_group_id = '75fe98d2-6549-46a1-aa04-a1c621e21d9e'
),

booking as (
    select
         app.business_id
        ,to_char(dec.created_at, 'YYYY-MM')  as booking_month
    from FIVETRAN_DB.PROD_NOVO_API_PUBLIC.CREDIT_CARD_APPLICATIONS            app
    join FIVETRAN_DB.PROD_NOVO_API_PUBLIC.CREDIT_CARD_APPLICATION_DECISIONS   dec
        on dec.application_id = app.id
    where dec.decision = 'APPROVED'
      and app.business_id not in (select business_id from excluded_businesses)
),

stmts_ranked as (
    select
         s.business_id
        ,s.created_at::date              as statement_date
        ,s.start_date::date              as billing_start
        ,s.end_date::date                as billing_end
        ,s.payment_due_date::date        as payment_due_date
        ,s.statement_balance  / 100.0    as statement_balance
        ,s.minimum_payment_due / 100.0   as min_payment_due
        ,row_number() over (
             partition by s.business_id
             order by s.created_at asc
         )                               as stmt_seq
    from FIVETRAN_DB.PROD_NOVO_API_PUBLIC.CREDIT_CARD_STATEMENTS s
    where s.business_id not in (select business_id from excluded_businesses)
),

stmt1 as (select * from stmts_ranked where stmt_seq = 1),
stmt2 as (select * from stmts_ranked where stmt_seq = 2),

-- Loan tape at billing period 2, latest record version per (business_id, statement_date)
tape_s2 as (
    select
         lt.business_id
        ,lt.statement_date
        ,lt.ending_balance          / 100.0  as ending_balance
        ,lt.credit_limit            / 100.0  as credit_limit
        ,lt.period_purchases        / 100.0  as period_purchases
        ,lt.daily_balance_purchases / 100.0  as avg_daily_balance
        ,lt.days_past_due
        ,lt.grace_period
    from PROD_DB.DATA.CREDIT_CARD_ACCOUNT_LOAN_TAPE_HISTORY lt
    where lt.billing_period_number = 2
      and lt.business_id not in (select business_id from excluded_businesses)
    qualify row_number() over (
        partition by lt.business_id, lt.statement_date
        order by lt.record_version desc
    ) = 1
),

-- Settled payments in the statement-1 window: statement issue date → due date
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

-- Autopay enrollment as of statement-2 close date (point-in-time)
autopay as (
    select distinct ap.business_id
    from FIVETRAN_DB.PROD_NOVO_API_PUBLIC.CREDIT_CARD_AUTOPAY_INSTRUCTIONS ap
    join tape_s2 t
        on  t.business_id          = ap.business_id
    where ap.created_at::date     <= t.statement_date
      and (ap.status = 'active' or ap.updated_at::date > t.statement_date)
),

-- Settled purchase transactions during the statement-2 billing window
txns as (
    select
         tx.business_id
        ,count(*)                   as tx_count
        ,max(tx.created_at::date)   as last_tx_date
    from FIVETRAN_DB.PROD_NOVO_API_PUBLIC.CREDIT_CARD_TRANSACTIONS tx
    join stmt2 s2
        on  s2.business_id     = tx.business_id
        and tx.created_at::date between s2.billing_start and s2.billing_end
    where tx.status = 'settled'
      and tx.result = 'APPROVED'
      and tx.business_id not in (select business_id from excluded_businesses)
    group by 1
),

-- Activation: account made at least one purchase across billing periods 1 or 2
activated as (
    select business_id
    from (
        select
             lt.business_id
            ,lt.period_purchases
        from PROD_DB.DATA.CREDIT_CARD_ACCOUNT_LOAN_TAPE_HISTORY lt
        where lt.billing_period_number in (1, 2)
          and lt.business_id not in (select business_id from excluded_businesses)
        qualify row_number() over (
            partition by lt.business_id, lt.statement_date
            order by lt.record_version desc
        ) = 1
    )
    group by 1
    having max(period_purchases) > 0
)

select
     b.booking_month

    ,count(distinct t.business_id)                                           as accounts_at_stmt2

    -- ── Payment behavior ────────────────────────────────────────────────────
    -- Missed: DPD >= 1 at statement 2 means statement-1 payment was not made by due date
    ,round(100.0
        * sum(case when t.days_past_due >= 1 then 1 else 0 end)
        / nullif(count(*), 0), 1)                                            as missed_payment_rate_pct

    -- Min only: paid >= 90% of min due but < 90% of full statement balance
    -- Denominator excludes accounts with $0 statement-1 balance
    ,round(100.0
        * sum(case
              when s1.statement_balance > 0
               and coalesce(p.total_paid, 0) > 0
               and coalesce(p.total_paid, 0) >= s1.min_payment_due   * 0.9
               and coalesce(p.total_paid, 0) <  s1.statement_balance * 0.9
              then 1 else 0 end)
        / nullif(count(case when s1.statement_balance > 0 then 1 end), 0), 1)
                                                                             as min_payment_only_rate_pct

    -- Payment ratio: total paid / statement-1 balance; null where balance was $0
    ,round(avg(case
               when s1.statement_balance > 0
               then coalesce(p.total_paid, 0) / s1.statement_balance
               end), 3)                                                      as avg_payment_ratio

    -- Full payment: grace_period = TRUE at statement 2 means paid in full last cycle
    ,round(100.0
        * sum(case when t.grace_period = true then 1 else 0 end)
        / nullif(count(*), 0), 1)                                            as full_payment_rate_pct

    ,round(100.0
        * count(distinct ap.business_id)
        / nullif(count(distinct t.business_id), 0), 1)                      as autopay_enrollment_rate_pct

    -- ── Balance & utilization ────────────────────────────────────────────────
    ,round(avg(t.period_purchases), 2)                                       as avg_purchase_volume
    ,round(sum(t.period_purchases), 2)                                       as total_purchase_volume
    ,round(avg(case
               when t.credit_limit > 0
               then t.ending_balance / t.credit_limit
               end), 3)                                                      as avg_utilization_rate
    ,round(avg(t.avg_daily_balance), 2)                                      as avg_daily_balance

    -- ── Activation & engagement ──────────────────────────────────────────────
    ,round(100.0
        * count(distinct act.business_id)
        / nullif(count(distinct t.business_id), 0), 1)                      as activation_rate_pct

    ,round(avg(coalesce(tx.tx_count, 0)), 1)                                as avg_tx_count

    -- Days since last purchase as of statement-2 close; null for accounts with no stmt-2 txns
    ,round(avg(case
               when tx.last_tx_date is not null
               then datediff('day', tx.last_tx_date, t.statement_date)
               end), 1)                                                      as avg_days_since_last_tx

from tape_s2         t
join  booking        b   on  b.business_id   = t.business_id
left  join stmt1     s1  on  s1.business_id  = t.business_id
left  join pmts      p   on  p.business_id   = t.business_id
left  join autopay   ap  on  ap.business_id  = t.business_id
left  join txns      tx  on  tx.business_id  = t.business_id
left  join activated act on  act.business_id = t.business_id

where b.booking_month >= '2024-11'

group by 1
order by 1
;
