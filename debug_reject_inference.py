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
cur = conn.cursor()
cur.execute("USE WAREHOUSE COMPUTE_WH")

def run(label, sql):
    print(f"\n{'='*60}")
    print(f">> {label}")
    print('='*60)
    cur.execute(sql)
    cols = [d[0] for d in cur.description]
    rows = cur.fetchall()
    print("  " + " | ".join(cols))
    print("  " + "-" * 60)
    for r in rows:
        print("  " + " | ".join(str(x) for x in r))
    if not rows:
        print("  (no rows)")

# ── 1. Booking universe ───────────────────────────────────────────────────────
run("1. Approved accounts booked 2026-03+ (raw count before dedup)", """
select
     to_char(app.created_at, 'YYYY-MM')  as booking_month
    ,count(distinct app.business_id)     as n_businesses
    ,count(*)                            as n_apps
from FIVETRAN_DB.PROD_NOVO_API_PUBLIC.CREDIT_CARD_APPLICATIONS app
join FIVETRAN_DB.PROD_NOVO_API_PUBLIC.CREDIT_CARD_ACCOUNTS ca
    on ca.business_id = app.business_id
where app.status = 'APPROVED'
  and coalesce(ca._fivetran_deleted, false) = false
  and to_char(app.created_at, 'YYYY-MM') >= '2026-03'
  and app.business_id not in (
      select business_id
      from PROD_DB.DBT_OUTPUT.BUSINESS_GROUP_ASSIGNMENTS
      where business_group_id = '75fe98d2-6549-46a1-aa04-a1c621e21d9e'
  )
group by 1
order by 1
""")

# ── 2. After acct dedup (rn=1) ────────────────────────────────────────────────
run("2. Booking CTE result (after all dedup logic)", """
with excluded_businesses as (
    select business_id from PROD_DB.DBT_OUTPUT.BUSINESS_GROUP_ASSIGNMENTS
    where business_group_id = '75fe98d2-6549-46a1-aa04-a1c621e21d9e'
),
acct_dedup as (
    select
         a.business_id, a.external_account_id
        ,row_number() over (partition by a.external_account_id order by a.created_at desc) as rn_dup
    from FIVETRAN_DB.PROD_NOVO_API_PUBLIC.CREDIT_CARD_ACCOUNTS a
    where coalesce(a._fivetran_deleted, false) = false
),
acct as (
    select business_id, external_account_id
          ,row_number() over (partition by business_id order by external_account_id) as rn
    from acct_dedup where rn_dup = 1
),
app_booking as (
    select business_id, min(created_at) as created_at
    from FIVETRAN_DB.PROD_NOVO_API_PUBLIC.CREDIT_CARD_APPLICATIONS
    where status = 'APPROVED'
    group by 1
)
select
     to_char(app.created_at, 'YYYY-MM') as booking_month
    ,count(*)                           as n_accounts
from acct a
join app_booking app on app.business_id = a.business_id
where a.rn = 1
  and to_char(app.created_at, 'YYYY-MM') >= '2026-03'
  and a.business_id not in (select business_id from excluded_businesses)
group by 1 order by 1
""")

# ── 3. Stmt1 coverage ─────────────────────────────────────────────────────────
run("3. stmt1 coverage: how many 2026-03+ accounts have a first statement", """
with excluded_businesses as (
    select business_id from PROD_DB.DBT_OUTPUT.BUSINESS_GROUP_ASSIGNMENTS
    where business_group_id = '75fe98d2-6549-46a1-aa04-a1c621e21d9e'
),
acct_dedup as (
    select a.business_id
          ,row_number() over (partition by a.external_account_id order by a.created_at desc) as rn_dup
    from FIVETRAN_DB.PROD_NOVO_API_PUBLIC.CREDIT_CARD_ACCOUNTS a
    where coalesce(a._fivetran_deleted, false) = false
),
acct as (
    select business_id
          ,row_number() over (partition by business_id order by business_id) as rn
    from acct_dedup where rn_dup = 1
),
app_booking as (
    select business_id, min(created_at) as created_at
    from FIVETRAN_DB.PROD_NOVO_API_PUBLIC.CREDIT_CARD_APPLICATIONS
    where status = 'APPROVED'
    group by 1
),
booking as (
    select a.business_id, app.created_at::date as booking_date, to_char(app.created_at, 'YYYY-MM') as booking_month
    from acct a
    join app_booking app on app.business_id = a.business_id
    where a.rn = 1
      and to_char(app.created_at, 'YYYY-MM') >= '2026-03'
      and a.business_id not in (select business_id from excluded_businesses)
)
select
     b.booking_month
    ,count(distinct b.business_id)  as booked
    ,count(distinct s.business_id)  as has_stmt1
    ,count(distinct case when s.payment_due_date::date < current_date() then s.business_id end) as stmt1_due_passed
    ,max(s.payment_due_date::date)  as max_stmt1_due_date
    ,max(coalesce(s.payment_due_date::date, dateadd(day, 60, b.booking_date))) as max_baked_fallback
from booking b
left join (
    select s.business_id, s.payment_due_date
    from FIVETRAN_DB.PROD_NOVO_API_PUBLIC.CREDIT_CARD_STATEMENTS s
    qualify row_number() over (partition by s.business_id order by s.created_at asc) = 1
) s on s.business_id = b.business_id
group by 1 order by 1
""")

# ── 4. baked_cohorts result ───────────────────────────────────────────────────
run("4. baked_cohorts: which booking months qualify (max fallback_due < today)", """
with excluded_businesses as (
    select business_id from PROD_DB.DBT_OUTPUT.BUSINESS_GROUP_ASSIGNMENTS
    where business_group_id = '75fe98d2-6549-46a1-aa04-a1c621e21d9e'
),
acct_dedup as (
    select a.business_id
          ,row_number() over (partition by a.external_account_id order by a.created_at desc) as rn_dup
    from FIVETRAN_DB.PROD_NOVO_API_PUBLIC.CREDIT_CARD_ACCOUNTS a
    where coalesce(a._fivetran_deleted, false) = false
),
acct as (
    select business_id
          ,row_number() over (partition by business_id order by business_id) as rn
    from acct_dedup where rn_dup = 1
),
app_booking as (
    select business_id, min(created_at) as created_at
    from FIVETRAN_DB.PROD_NOVO_API_PUBLIC.CREDIT_CARD_APPLICATIONS
    where status = 'APPROVED'
    group by 1
),
booking as (
    select a.business_id, app.created_at::date as booking_date, to_char(app.created_at, 'YYYY-MM') as booking_month
    from acct a
    join app_booking app on app.business_id = a.business_id
    where a.rn = 1
      and to_char(app.created_at, 'YYYY-MM') >= '2026-03'
      and a.business_id not in (select business_id from excluded_businesses)
),
stmt1 as (
    select s.business_id, s.payment_due_date::date as payment_due_date, s.start_date::date as billing_start, s.end_date::date as billing_end
    from FIVETRAN_DB.PROD_NOVO_API_PUBLIC.CREDIT_CARD_STATEMENTS s
    join booking b on b.business_id = s.business_id
    qualify row_number() over (partition by s.business_id order by s.created_at asc) = 1
)
select
     b.booking_month
    ,count(distinct b.business_id)                                                            as total_accounts
    ,max(coalesce(s1.payment_due_date, dateadd(day, 60, b.booking_date)))                     as max_fallback_due
    ,iff(max(coalesce(s1.payment_due_date, dateadd(day, 60, b.booking_date))) < current_date(), 'BAKED', 'NOT BAKED') as status
from booking b
left join stmt1 s1 on s1.business_id = b.business_id
group by 1 order by 1
""")

# ── 5. Final query without the baked filter (to see if data exists at all) ────
run("5. Final query result WITHOUT baked_cohorts filter (ungated)", """
with excluded_businesses as (
    select business_id from PROD_DB.DBT_OUTPUT.BUSINESS_GROUP_ASSIGNMENTS
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
    left join latest_invite li    on li.business_id    = b.business_id
    left join PROD_DB.ADHOC.RISK_BUCKET_RETRO_SCORE_MAY4  retro on retro.business_id = b.business_id
    left join PROD_DB.ADHOC.CC_APR_CAMPAIGN_MODEL_BUCKET  apr   on apr.business_id   = b.business_id
    left join PROD_DB.DE.CC_NEW_ACCOUNT_MODEL_UW          may   on may.business_id   = b.business_id
),
acct_dedup as (
    select a.business_id, a.external_account_id
          ,row_number() over (partition by a.external_account_id order by a.created_at desc) as rn_dup
    from FIVETRAN_DB.PROD_NOVO_API_PUBLIC.CREDIT_CARD_ACCOUNTS a
    where coalesce(a._fivetran_deleted, false) = false
),
acct as (
    select business_id, external_account_id
          ,row_number() over (partition by business_id order by external_account_id) as rn
    from acct_dedup where rn_dup = 1
),
app_booking as (
    select business_id, min(created_at) as created_at
    from FIVETRAN_DB.PROD_NOVO_API_PUBLIC.CREDIT_CARD_APPLICATIONS
    where status = 'APPROVED'
    group by 1
),
booking as (
    select a.business_id, a.external_account_id
          ,app.created_at::date as booking_date
          ,to_char(app.created_at, 'YYYY-MM') as booking_month
          ,coalesce(rb.risk_bucket, 'Reject Inference') as risk_bucket
    from acct a
    join app_booking app on app.business_id = a.business_id
    left join risk_bucket_lookup rb on rb.business_id = a.business_id
    where a.rn = 1
      and to_char(app.created_at, 'YYYY-MM') >= '2026-03'
      and a.business_id not in (select business_id from excluded_businesses)
),
stmt1 as (
    select s.business_id
          ,s.created_at::date as statement_date
          ,s.start_date::date as billing_start
          ,s.end_date::date as billing_end
          ,s.payment_due_date::date as payment_due_date
          ,s.statement_balance / 100.0 as statement_balance
    from FIVETRAN_DB.PROD_NOVO_API_PUBLIC.CREDIT_CARD_STATEMENTS s
    join booking b on b.business_id = s.business_id
    qualify row_number() over (partition by s.business_id order by s.created_at asc) = 1
)
select
     b.risk_bucket
    ,b.booking_month
    ,count(distinct b.business_id)   as total_booked
    ,count(distinct s1.business_id)  as has_stmt1
    ,count(distinct case when s1.payment_due_date < current_date() then s1.business_id end) as stmt1_baked
from booking b
left join stmt1 s1 on s1.business_id = b.business_id
group by 1, 2
order by 2, 1
""")

conn.close()
print("\nDone.")