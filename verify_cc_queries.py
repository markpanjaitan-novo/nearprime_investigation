"""
verify_cc_queries.py
Verifies the three highest-impact issues found in dashboard_queries.sql CC queries:
  1. Q6  — Rewards sign error: rewards / 100 vs rewards * -1 / 100
  2. Q4  — Loan tape dedup bug: ROW_NUMBER defined but never applied
  3. Q2  — F&F exclusion missing from invite funnel
"""

import tomli as tomllib
from pathlib import Path
import snowflake.connector, warnings
warnings.filterwarnings("ignore")

cfg = tomllib.loads(Path.home().joinpath(".snowflake/connections.toml").read_text())
profile = cfg["A6040307054171-BANK_NOVO_ENTERPRISE"]

print("Connecting (check browser for SSO)...", flush=True)
conn = snowflake.connector.connect(
    account=profile["account"],
    user=profile["user"],
    authenticator=profile.get("authenticator"),
    role="BI_ROLE",
    warehouse="COMPUTE_WH",
    database="PROD_DB",
    schema="ADHOC",
)
print("Connected.\n", flush=True)

def run(sql):
    cur = conn.cursor()
    cur.execute(sql)
    cols = [d[0].lower() for d in cur.description]
    return cols, cur.fetchall()

def pt(cols, rows, indent=2):
    if not rows:
        print(" " * indent + "(no rows)")
        return
    pad = " " * indent
    widths = [max(len(str(c)), max(len(str(r[i])) for r in rows)) for i, c in enumerate(cols)]
    fmt = "  ".join(f"{{:<{w}}}" for w in widths)
    print(pad + fmt.format(*cols))
    print(pad + "  ".join("-" * w for w in widths))
    for row in rows:
        print(pad + fmt.format(*[str(v) if v is not None else "NULL" for v in row]))

def section(title):
    print("\n" + "=" * 72)
    print(f"  {title}")
    print("=" * 72)

EXCL = """
    SELECT business_id FROM FIVETRAN_DB.PROD_NOVO_API_PUBLIC.BUSINESS_GROUP_ASSIGNMENTS
    WHERE business_group_id = '75fe98d2-6549-46a1-aa04-a1c621e21d9e'
"""


# ════════════════════════════════════════════════════════════════════════════
# CHECK 1 — Q6: Rewards sign error
#
# CLAUDE.md: CREDIT_CARD_TRANSACTION_REWARD_ITEMS.rewards is stored as
# NEGATIVE CENTS. Correct transform: rewards * -1 / 100.
#
# Q6 uses: SUM(rewards / 100) → negative dollar amount.
# In the NIBT formula: revenue - reward_accrued
#   Wrong:   revenue - (negative)  = revenue + rewards  ← inflates NIBT
#   Correct: revenue - (positive)  = revenue - rewards  ← correctly reduces NIBT
#
# We compare:
#   a) reward_accrued as-is (Q6 behaviour: rewards / 100)
#   b) reward_accrued corrected (rewards * -1 / 100)
#   c) NIBT delta = correct_nibt - wrong_nibt = 2 * reward_dollars per month
# ════════════════════════════════════════════════════════════════════════════
section("CHECK 1 — Q6: Rewards sign error impact on NIBT (2025-11 onward)")

cols, rows = run(f"""
-- Rewards are joined to statements via cc_account_id + billing window (start_date/end_date).
-- We use CREDIT_CARD_STATEMENTS to get the billing window, then sum rewards per month.
WITH accts AS (
    SELECT id AS cc_account_id, business_id
    FROM FIVETRAN_DB.PROD_NOVO_API_PUBLIC.CREDIT_CARD_ACCOUNTS
    WHERE business_id NOT IN ({EXCL})
      AND COALESCE(_fivetran_deleted, FALSE) = FALSE
),
stmt_windows AS (
    SELECT s.business_id,
           TO_CHAR(s.created_at, 'YYYY-MM') AS stmt_month,
           s.start_date,
           s.end_date,
           a.cc_account_id
    FROM FIVETRAN_DB.PROD_NOVO_API_PUBLIC.CREDIT_CARD_STATEMENTS s
    JOIN accts a ON a.business_id = s.business_id
    WHERE TO_CHAR(s.created_at, 'YYYY-MM') >= '2025-11'
),
rewards_by_stmt AS (
    SELECT
        sw.stmt_month,
        -- Q6 formula: rewards / 100 → negative (sign error)
        ROUND(SUM(r.rewards / 100.0), 2)        AS q6_reward_accrued,
        -- Correct formula: rewards * -1 / 100 → positive cost
        ROUND(SUM(r.rewards * -1 / 100.0), 2)   AS correct_reward_cost
    FROM stmt_windows sw
    LEFT JOIN FIVETRAN_DB.PROD_NOVO_API_PUBLIC.CREDIT_CARD_TRANSACTION_REWARD_ITEMS r
        ON r.credit_card_account_id = sw.cc_account_id
       AND TO_CHAR(r.created_at, 'YYYY-MM-DD') BETWEEN sw.start_date AND sw.end_date
    GROUP BY 1
)
SELECT
    stmt_month,
    q6_reward_accrued,
    correct_reward_cost,
    -- NIBT formula is: revenue - reward_accrued
    -- Wrong:   revenue - (q6_reward_accrued)   = revenue - (negative) = revenue + |rewards|
    -- Correct: revenue - (correct_reward_cost)  = revenue - (positive) = revenue - |rewards|
    -- Overstatement = correct_nibt - wrong_nibt = -2 * correct_reward_cost
    ROUND(-2 * correct_reward_cost, 2) AS nibt_overstatement_by_q6
FROM rewards_by_stmt
ORDER BY stmt_month DESC
""")
pt(cols, rows)
print("""
  q6_reward_accrued    = Q6's formula (SUM(rewards/100)) → should be negative (rewards are negative cents)
  correct_reward_cost  = corrected (SUM(rewards * -1 / 100)) → positive dollar cost
  reward_sign_delta    = correct - wrong  (should equal 2× the dollar amount if signs are mirror images)
  nibt_overstatement   = how much Q6 OVERSTATES NIBT due to the sign reversal""")


# ════════════════════════════════════════════════════════════════════════════
# CHECK 2 — Q4/Q7/Q8: Loan tape dedup bug
#
# In Q4, Q7, Q8: ROW_NUMBER is computed in loan_tape_updated but the
# downstream CTE never filters WHERE rn = 1.
#
# Impact: if any (business_id, statement_date) has record_version > 1,
# those rows appear multiple times, inflating ending_balance sums.
#
# We check: how many (business_id, statement_date) pairs in the
# 2-days-ago snapshot have more than one record_version?
# ════════════════════════════════════════════════════════════════════════════
section("CHECK 2 — Q4/Q7/Q8: Loan tape dedup bug — record_version fan-out")

cols, rows = run(f"""
WITH raw AS (
    SELECT a.account_id, a.statement_date, a.record_version,
           a.ending_balance, a.days_past_due,
           b.business_id
    FROM PROD_DB.DATA.CREDIT_CARD_ACCOUNT_LOAN_TAPE_HISTORY a
    JOIN FIVETRAN_DB.PROD_NOVO_API_PUBLIC.CREDIT_CARD_ACCOUNTS b
        ON b.external_account_id = a.account_id
    WHERE b.business_id NOT IN ({EXCL})
      AND DATEDIFF(day, a.statement_date, CURRENT_DATE) = 2
      AND a.days_past_due >= 0
      AND a.ending_balance > 0
),
per_biz_stmt AS (
    SELECT business_id, statement_date,
           COUNT(*) AS version_count,
           MAX(ending_balance) AS max_ending_bal,
           MIN(ending_balance) AS min_ending_bal,
           MAX(ending_balance) - MIN(ending_balance) AS ending_bal_spread
    FROM raw
    GROUP BY 1, 2
)
SELECT
    COUNT(*) AS total_biz_stmt_pairs,
    SUM(CASE WHEN version_count > 1 THEN 1 ELSE 0 END) AS pairs_with_fanout,
    ROUND(100.0 * SUM(CASE WHEN version_count > 1 THEN 1 ELSE 0 END) / COUNT(*), 2) AS pct_fanout,
    SUM(CASE WHEN version_count > 1 THEN ending_bal_spread ELSE 0 END) / 100 AS total_balance_overcount_dollars
FROM per_biz_stmt
""")
pt(cols, rows)
print()

# If there IS fan-out, show how much it inflates Q4's bucket totals
print("  Comparing Q4 bucket totals: with vs without dedup filter...")
cols2, rows2 = run(f"""
WITH raw_no_dedup AS (
    SELECT b.business_id, a.days_past_due, a.ending_balance / 100.0 AS bal,
           a.statement_date,
           ROW_NUMBER() OVER (PARTITION BY b.business_id ORDER BY a.statement_date DESC) AS date_rank
    FROM PROD_DB.DATA.CREDIT_CARD_ACCOUNT_LOAN_TAPE_HISTORY a
    JOIN FIVETRAN_DB.PROD_NOVO_API_PUBLIC.CREDIT_CARD_ACCOUNTS b
        ON b.external_account_id = a.account_id
    WHERE b.business_id NOT IN ({EXCL})
      AND a.days_past_due >= 0
      AND a.ending_balance > 0
      AND DATEDIFF(day, a.statement_date, CURRENT_DATE) = 2
),
raw_with_dedup AS (
    SELECT b.business_id, a.days_past_due, a.ending_balance / 100.0 AS bal,
           a.statement_date,
           ROW_NUMBER() OVER (PARTITION BY b.business_id, a.statement_date ORDER BY a.record_version DESC) AS rn,
           ROW_NUMBER() OVER (PARTITION BY b.business_id ORDER BY a.statement_date DESC) AS date_rank
    FROM PROD_DB.DATA.CREDIT_CARD_ACCOUNT_LOAN_TAPE_HISTORY a
    JOIN FIVETRAN_DB.PROD_NOVO_API_PUBLIC.CREDIT_CARD_ACCOUNTS b
        ON b.external_account_id = a.account_id
    WHERE b.business_id NOT IN ({EXCL})
      AND a.days_past_due >= 0
      AND a.ending_balance > 0
      AND DATEDIFF(day, a.statement_date, CURRENT_DATE) = 2
)
SELECT
    'WITHOUT dedup (Q4 as-written)'      AS query_version,
    ROUND(SUM(CASE WHEN days_past_due = 0              THEN bal ELSE 0 END), 0) AS current_bal,
    ROUND(SUM(CASE WHEN days_past_due BETWEEN 1 AND 29 THEN bal ELSE 0 END), 0) AS d1_29_bal,
    ROUND(SUM(bal), 0)                                                            AS total_ar
FROM raw_no_dedup WHERE date_rank = 1
UNION ALL
SELECT
    'WITH dedup (correct)'                AS query_version,
    ROUND(SUM(CASE WHEN days_past_due = 0              THEN bal ELSE 0 END), 0) AS current_bal,
    ROUND(SUM(CASE WHEN days_past_due BETWEEN 1 AND 29 THEN bal ELSE 0 END), 0) AS d1_29_bal,
    ROUND(SUM(bal), 0)                                                            AS total_ar
FROM raw_with_dedup WHERE date_rank = 1 AND rn = 1
ORDER BY query_version
""")
pt(cols2, rows2)


# ════════════════════════════════════════════════════════════════════════════
# CHECK 3 — Q2: F&F accounts in May 2026 CC invitations
#
# Q2 has no F&F exclusion. How many invited businesses in the May 2026
# campaign are F&F accounts?
# ════════════════════════════════════════════════════════════════════════════
section("CHECK 3 — Q2: F&F accounts in May 2026 CC invite cohort")

cols, rows = run(f"""
WITH inv AS (
    SELECT DISTINCT business_id, FICO_SCORE
    FROM FIVETRAN_DB.PROD_NOVO_API_PUBLIC.CREDIT_CARD_INVITATIONS
    WHERE created_at >= '2026-05-28'
),
ff AS (
    SELECT business_id FROM FIVETRAN_DB.PROD_NOVO_API_PUBLIC.BUSINESS_GROUP_ASSIGNMENTS
    WHERE business_group_id = '75fe98d2-6549-46a1-aa04-a1c621e21d9e'
)
SELECT
    COUNT(DISTINCT i.business_id)                                       AS total_invited_no_excl,
    COUNT(DISTINCT CASE WHEN f.business_id IS NOT NULL THEN i.business_id END) AS ff_in_cohort,
    COUNT(DISTINCT CASE WHEN f.business_id IS NULL     THEN i.business_id END) AS non_ff_invited,
    ROUND(AVG(CASE WHEN f.business_id IS NULL THEN i.fico_score END), 1) AS avg_fico_non_ff,
    ROUND(AVG(CASE WHEN f.business_id IS NOT NULL THEN i.fico_score END), 1) AS avg_fico_ff
FROM inv i
LEFT JOIN ff f ON f.business_id = i.business_id
""")
pt(cols, rows)

# Also check how many F&F had approved applications in May 2026
print()
cols2, rows2 = run(f"""
WITH ff AS (
    SELECT business_id FROM FIVETRAN_DB.PROD_NOVO_API_PUBLIC.BUSINESS_GROUP_ASSIGNMENTS
    WHERE business_group_id = '75fe98d2-6549-46a1-aa04-a1c621e21d9e'
)
SELECT
    COUNT(*) AS ff_approved_apps_may2026,
    ROUND(AVG(credit_limit / 100.0), 0) AS avg_limit
FROM FIVETRAN_DB.PROD_NOVO_API_PUBLIC.CREDIT_CARD_APPLICATIONS a
JOIN ff ON ff.business_id = a.business_id
WHERE status = 'APPROVED'
  AND TO_CHAR(created_at, 'YYYY-MM') = '2026-05'
""")
pt(cols2, rows2)

conn.close()
print("\n\nDone.")