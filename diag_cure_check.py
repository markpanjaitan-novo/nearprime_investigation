"""Diagnostic: account-level payment picture for stmt1 delinquents.

For every account that was delinquent at its stmt1 due date (paid < min due),
show min due, what was paid by due date, what was paid in the 21-day cure
window, and ALL post-due payment activity regardless of window or status —
so we can see why cured_within_21d_count reads 0.
"""
import snowflake.connector, tomli as tomllib
from pathlib import Path

cfg = tomllib.loads(Path.home().joinpath(".snowflake/connections.toml").read_text())
profile = cfg["A6040307054171-BANK_NOVO_ENTERPRISE"]

conn = snowflake.connector.connect(
    account=profile["account"],
    user=profile["user"],
    authenticator=profile.get("authenticator"),
    role="BI_ROLE",
    warehouse="COMPUTE_WH",
    database="PROD_DB",
    schema="ADHOC",
)

SQL = """
with excluded_businesses as (
    select business_id
    from PROD_DB.DBT_OUTPUT.BUSINESS_GROUP_ASSIGNMENTS
    where business_group_id = '75fe98d2-6549-46a1-aa04-a1c621e21d9e'
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
        ,to_char(app.created_at, 'YYYY-MM') as booking_month
    from acct a
    join app_booking app on app.business_id = a.business_id
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
        ,row_number() over (partition by s.business_id order by s.created_at asc) as rn
    from FIVETRAN_DB.PROD_NOVO_API_PUBLIC.CREDIT_CARD_STATEMENTS s
    join booking b on b.business_id = s.business_id
    qualify rn = 1
),

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

late_pmts as (
    select
         p.business_id
        ,sum(p.amount) / 100.0  as total_paid
    from FIVETRAN_DB.PROD_NOVO_API_PUBLIC.CREDIT_CARD_PAYMENTS p
    join stmt1 s1
        on  s1.business_id     = p.business_id
        and p.created_at::date >  s1.payment_due_date
        and p.created_at::date <= dateadd(day, 21, s1.payment_due_date)
    where p.status = 'settled'
    group by 1
),

-- everything after due date, no window cap, no status filter
post_due_all as (
    select
         p.business_id
        ,count(*)                                                  as pmt_rows_after_due
        ,min(p.created_at::date)                                   as first_pmt_after_due
        ,max(p.created_at::date)                                   as last_pmt_after_due
        ,sum(p.amount) / 100.0                                     as all_amt_after_due
        ,sum(case when p.status = 'settled'
             then p.amount end) / 100.0                            as settled_amt_after_due
        ,listagg(distinct p.status, ',')
             within group (order by p.status)                      as statuses_after_due
    from FIVETRAN_DB.PROD_NOVO_API_PUBLIC.CREDIT_CARD_PAYMENTS p
    join stmt1 s1
        on  s1.business_id     = p.business_id
        and p.created_at::date > s1.payment_due_date
    group by 1
)

select
     b.business_id
    ,s1.payment_due_date
    ,dateadd(day, 21, s1.payment_due_date)        as cure_window_end
    ,(dateadd(day, 21, s1.payment_due_date) >= current_date()) as window_still_open
    ,s1.statement_balance
    ,s1.min_payment_due
    ,coalesce(p.total_paid, 0)                    as settled_paid_by_due
    ,coalesce(lp.total_paid, 0)                   as settled_paid_in_21d
    ,pd.pmt_rows_after_due
    ,pd.first_pmt_after_due
    ,pd.last_pmt_after_due
    ,pd.all_amt_after_due
    ,pd.settled_amt_after_due
    ,pd.statuses_after_due
from booking b
join stmt1 s1
    on  s1.business_id = b.business_id
    and s1.payment_due_date < current_date()
left join pmts         p  on p.business_id  = b.business_id
left join late_pmts    lp on lp.business_id = b.business_id
left join post_due_all pd on pd.business_id = b.business_id
where s1.statement_balance > 0
  and coalesce(p.total_paid, 0) < s1.min_payment_due
order by s1.payment_due_date
"""

cur = conn.cursor()
cur.execute(SQL)
cols = [c[0] for c in cur.description]
rows = cur.fetchall()
print(f"{len(rows)} delinquent-at-due accounts\n")
for r in rows:
    print("-" * 70)
    for c, v in zip(cols, r):
        print(f"  {c:<25} {v}")

# Also: distinct payment statuses present in the table at all
cur.execute("""
    select status, count(*)
    from FIVETRAN_DB.PROD_NOVO_API_PUBLIC.CREDIT_CARD_PAYMENTS
    group by 1 order by 2 desc
""")
print("\nAll payment statuses in CREDIT_CARD_PAYMENTS:")
for r in cur.fetchall():
    print(f"  {r[0]:<20} {r[1]}")

conn.close()