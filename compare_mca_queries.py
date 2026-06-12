"""
compare_mca_queries.py
Compares nearprime Q9 / Q10 / Q11 against inlined dashboard logic.
Runs queries against Snowflake directly (no views need to exist).
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

# ── helpers ──────────────────────────────────────────────────────────────────
def run(sql: str):
    cur = conn.cursor()
    cur.execute(sql)
    cols = [d[0].lower() for d in cur.description]
    return cols, cur.fetchall()

def pt(cols, rows, indent=0):
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

# Shared exclusion subquery (same business_group_id used in CC nearprime queries).
EXCL = """
    SELECT DISTINCT business_id
    FROM FIVETRAN_DB.PROD_NOVO_API_PUBLIC.BUSINESS_GROUP_ASSIGNMENTS
    WHERE business_group_id = '75fe98d2-6549-46a1-aa04-a1c621e21d9e'
"""


# ════════════════════════════════════════════════════════════════════════════
# Q9  —  Booked account counts by month
#
# Nearprime:  raw lending_businesses COUNT, no exclusion, no dedup
# Dashboard:  same base table, F&F excluded, deduped to one row per business_id
# ════════════════════════════════════════════════════════════════════════════
section("Q9 — Booked accounts by month (2026-01 onward)")

cols_np9, rows_np9 = run(f"""
SELECT
    TO_CHAR(created_at, 'YYYY-MM') AS booking_month,
    COUNT(*)                        AS np_count
FROM FIVETRAN_DB.PROD_NOVO_API_PUBLIC.LENDING_BUSINESSES
WHERE TO_CHAR(created_at, 'YYYY-MM-DD') >= '2026-01-01'
GROUP BY 1
ORDER BY 1
""")

cols_db9, rows_db9 = run(f"""
WITH dedup AS (
    SELECT
        business_id,
        TO_CHAR(offer_accepted_at, 'YYYY-MM') AS booking_month,
        ROW_NUMBER() OVER (PARTITION BY business_id ORDER BY offer_accepted_at DESC NULLS LAST) AS rn
    FROM FIVETRAN_DB.PROD_NOVO_API_PUBLIC.LENDING_BUSINESSES
    WHERE business_id NOT IN ({EXCL})
      AND is_offer_accepted = TRUE
      AND application_status = 'approved'
)
SELECT booking_month, COUNT(*) AS db_count
FROM dedup
WHERE rn = 1 AND booking_month >= '2026-01'
GROUP BY 1
ORDER BY 1
""")

# merge
np_map  = {r[0]: r[1] for r in rows_np9}
db_map  = {r[0]: r[1] for r in rows_db9}
months  = sorted(set(np_map) | set(db_map))
merged9 = [
    (m, np_map.get(m, 0), db_map.get(m, 0), np_map.get(m, 0) - db_map.get(m, 0))
    for m in months
]
print("\nbooking_month  np_count  db_count  delta(np-db)")
print("-" * 48)
for booking_month, np, db, d in merged9:
    print(f"  {booking_month}        {np:<9} {db:<9} {d:+d}")
print()
print("  np_count = raw lending_businesses rows (no exclusion, no dedup)")
print("  db_count = deduped + F&F excluded + approved only")


# ════════════════════════════════════════════════════════════════════════════
# Q10  —  Invite funnel by CCR risk bin (May 2026 onward)
#
# Three dimensions tested:
#   A. CCR bin source table:
#        Nearprime → mca_uw_eligibility_base only (V2 table) for ALL era accounts
#        Dashboard → UW_3_SCORED_BASE_FOR_INVITES_F (V1 era) OR
#                    MCA_UW_ELIGIBILITY_BASE (V2 era)
#   B. Join precision:
#        Nearprime → month-level  (TO_CHAR match)
#        Dashboard → exact date   (run_date <= invited_at::DATE)
#   C. F&F exclusion:
#        Nearprime → none
#        Dashboard → excluded
# ════════════════════════════════════════════════════════════════════════════
section("Q10 — May 2026 invite funnel by risk_bin")

print("\n-- Nearprime Q10c (mca_uw_eligibility_base only, month join, no exclusion) --")
cols10np, rows10np = run(f"""
WITH inv AS (
    SELECT business_id, created_at
    FROM FIVETRAN_DB.PROD_NOVO_API_PUBLIC.LENDING_INVITATIONS
    WHERE TO_CHAR(created_at, 'YYYY-MM') >= '2026-05'
),
scored AS (
    SELECT a.business_id,
           COALESCE(CAST(b.risk_bin AS TEXT), 'NULL/no-match') AS risk_bin,
           b.fico_score
    FROM inv a
    LEFT JOIN PROD_DB.MODELS.MCA_UW_ELIGIBILITY_BASE b
           ON a.business_id = b.business_id
          AND TO_CHAR(a.created_at, 'YYYY-MM') = TO_CHAR(b.run_date, 'YYYY-MM')
),
inv_agg AS (
    SELECT risk_bin, COUNT(*) AS np_invited, ROUND(AVG(fico_score), 0) AS np_avg_fico
    FROM scored
    GROUP BY risk_bin
),
appr AS (
    SELECT business_id, credit_limit / 100 AS offer_limit
    FROM FIVETRAN_DB.PROD_NOVO_API_PUBLIC.LENDING_BUSINESSES
    WHERE TO_CHAR(created_at, 'YYYY-MM-DD') >= '2026-05-29'
),
appr_scored AS (
    SELECT a.business_id,
           COALESCE(CAST(b.risk_bin AS TEXT), 'NULL/no-match') AS risk_bin,
           a.offer_limit
    FROM appr a
    LEFT JOIN PROD_DB.MODELS.MCA_UW_ELIGIBILITY_BASE b
           ON a.business_id = b.business_id
          AND TO_CHAR('2026-05-01'::DATE, 'YYYY-MM') = TO_CHAR(b.run_date, 'YYYY-MM')
),
appr_agg AS (
    SELECT risk_bin, COUNT(*) AS np_approved, ROUND(AVG(offer_limit), 0) AS np_avg_limit
    FROM appr_scored
    GROUP BY risk_bin
)
SELECT
    COALESCE(i.risk_bin, a.risk_bin) AS risk_bin,
    COALESCE(i.np_invited,  0)       AS np_invited,
    COALESCE(a.np_approved, 0)       AS np_approved,
    i.np_avg_fico,
    a.np_avg_limit
FROM inv_agg i
FULL OUTER JOIN appr_agg a ON i.risk_bin = a.risk_bin
ORDER BY risk_bin
""")
pt(cols10np, rows10np, indent=2)

print("\n-- Dashboard (V1 table for V1-era, V2 table for V2-era, exact date join, F&F excluded) --")
cols10db, rows10db = run(f"""
WITH inv AS (
    SELECT a.business_id, a.created_at, a.id AS invite_id,
           TRIM(a.meta:inputVariables:CCR_BIN::TEXT) AS meta_bin
    FROM FIVETRAN_DB.PROD_NOVO_API_PUBLIC.LENDING_INVITATIONS a
    WHERE TO_CHAR(a.created_at, 'YYYY-MM') >= '2026-05'
      AND a.business_id NOT IN ({EXCL})
),
v2_score AS (
    SELECT bi.business_id, e.risk_bin AS bin
    FROM inv bi
    INNER JOIN PROD_DB.MODELS.MCA_UW_ELIGIBILITY_BASE e
           ON e.business_id = bi.business_id
          AND e.run_date   <= bi.created_at::DATE
    QUALIFY ROW_NUMBER() OVER (PARTITION BY bi.business_id ORDER BY e.run_date DESC) = 1
),
labelled AS (
    SELECT
        i.business_id,
        i.invite_id,
        CASE
            WHEN i.meta_bin IS NULL                               THEN 'Pre-CCR'
            WHEN TO_CHAR(i.created_at, 'YYYY-MM') < '2025-09'    THEN 'V1-' || COALESCE(NULLIF(TRIM(v2.bin::TEXT),''), NULLIF(i.meta_bin,''), '?')
            ELSE                                                      'V2-' || COALESCE(NULLIF(TRIM(v2.bin::TEXT),''), NULLIF(i.meta_bin,''), '?')
        END AS ccr_bin
    FROM inv i
    LEFT JOIN v2_score v2 ON v2.business_id = i.business_id
),
accepted AS (
    SELECT b.business_id, b.lending_invitation_id, b.credit_limit / 100 AS offer_limit
    FROM FIVETRAN_DB.PROD_NOVO_API_PUBLIC.LENDING_BUSINESSES b
    WHERE b.business_id NOT IN ({EXCL})
      AND b.is_offer_accepted = TRUE
      AND b.application_status = 'approved'
      AND TO_CHAR(b.created_at, 'YYYY-MM-DD') >= '2026-05-29'
),
inv_agg AS (
    SELECT ccr_bin, COUNT(DISTINCT business_id) AS db_invited
    FROM labelled
    GROUP BY ccr_bin
),
appr_agg AS (
    SELECT l.ccr_bin,
           COUNT(DISTINCT a.business_id)     AS db_approved,
           ROUND(AVG(a.offer_limit), 0)      AS db_avg_limit
    FROM accepted a
    LEFT JOIN labelled l ON l.invite_id = a.lending_invitation_id
    GROUP BY l.ccr_bin
)
SELECT
    COALESCE(i.ccr_bin, a.ccr_bin) AS ccr_bin,
    COALESCE(i.db_invited,  0)     AS db_invited,
    COALESCE(a.db_approved, 0)     AS db_approved,
    a.db_avg_limit
FROM inv_agg i
FULL OUTER JOIN appr_agg a ON i.ccr_bin = a.ccr_bin
ORDER BY ccr_bin
""")
pt(cols10db, rows10db, indent=2)

# Summary: overall invite and approved totals
np_inv_total  = sum(r[1] for r in rows10np)
np_appr_total = sum(r[2] for r in rows10np)
db_inv_total  = sum(r[1] for r in rows10db)
db_appr_total = sum(r[2] for r in rows10db)
print(f"\n  Totals:  np invited={np_inv_total:,}  db invited={db_inv_total:,}  delta={np_inv_total-db_inv_total:+,}")
print(f"           np approved={np_appr_total:,}  db approved={db_appr_total:,}  delta={np_appr_total-db_appr_total:+,}")

# How many invites get NULL bin from nearprime (V2 table miss)?
null_invited = next((r[1] for r in rows10np if r[0] == "NULL/no-match"), 0)
print(f"\n  Nearprime NULL/no-match invites (V2 table miss): {null_invited:,}")


# ════════════════════════════════════════════════════════════════════════════
# Q11  —  NIBT by report month (2025-11 onward)
#
# Differences:
#   • co_value cascade: nearprime = PBO→NACO→GACO; dashboard = GACO→PBO→0
#   • F&F:              nearprime = none;           dashboard = excluded
# ════════════════════════════════════════════════════════════════════════════
section("Q11 — NIBT by report month (2025-11 onward)")

cols_np11, rows_np11 = run(f"""
WITH bg AS (
    SELECT
        lt.business_id, lt.snap_date,
        MAX(lt.days_past_due)                      AS dpd,
        SUM(lt.principal_balance_outstanding)      AS pbo,
        SUM(lt.factor_fee_amount_paid_last_month)  AS ff_coll,
        SUM(lt.fee_amount_paid_last_month)         AS lf_coll,
        SUM(lt.gross_principal_amount_charged_off) AS gaco,
        SUM(lt.net_principal_amount_charged_off)   AS naco
    FROM PROD_DB.DATA.LOAN_TAPE lt
    WHERE DAY(lt.snap_date) = 1
    GROUP BY 1, 2
),
enriched AS (
    SELECT
        bg.*,
        TO_CHAR(bg.snap_date - 1, 'YYYY-MM') AS report_month,
        -- nearprime cascade: PBO → NACO (if recovery) → GACO
        CASE
            WHEN COALESCE(bg.pbo,  0) > 0                              THEN bg.pbo
            WHEN (COALESCE(bg.gaco,0) - COALESCE(bg.naco,0)) > 0      THEN bg.naco
            ELSE COALESCE(bg.gaco, 0)
        END AS co_value
    FROM bg
)
SELECT
    report_month,
    ROUND(SUM(ff_coll + lf_coll), 2)                            AS np_revenue,
    ROUND(SUM(CASE WHEN dpd BETWEEN 180 AND 209 THEN co_value ELSE 0 END), 2) AS np_gaco,
    ROUND(SUM(ff_coll + lf_coll
              - CASE WHEN dpd BETWEEN 180 AND 209 THEN co_value ELSE 0 END), 2) AS np_nibt
FROM enriched
WHERE report_month IS NOT NULL AND report_month >= '2025-11'
GROUP BY 1
ORDER BY 1 DESC
""")

cols_db11, rows_db11 = run(f"""
WITH bg AS (
    SELECT
        lt.business_id, lt.snap_date,
        MAX(lt.days_past_due)                      AS dpd,
        SUM(lt.principal_balance_outstanding)      AS pbo,
        SUM(lt.factor_fee_amount_paid_last_month)  AS ff_coll,
        SUM(lt.fee_amount_paid_last_month)         AS lf_coll,
        SUM(lt.gross_principal_amount_charged_off) AS gaco,
        SUM(lt.net_principal_amount_charged_off)   AS naco
    FROM PROD_DB.DATA.LOAN_TAPE lt
    LEFT JOIN ({EXCL}) excl ON excl.business_id = lt.business_id
    WHERE DAY(lt.snap_date) = 1
      AND excl.business_id IS NULL
    GROUP BY 1, 2
),
enriched AS (
    SELECT
        bg.*,
        TO_CHAR(bg.snap_date - 1, 'YYYY-MM') AS report_month,
        -- dashboard cascade: GACO → PBO → 0
        CASE
            WHEN COALESCE(bg.gaco, 0) > 0  THEN bg.gaco
            WHEN COALESCE(bg.pbo,  0) > 0  THEN bg.pbo
            ELSE 0
        END AS co_value
    FROM bg
)
SELECT
    report_month,
    ROUND(SUM(ff_coll + lf_coll), 2)                            AS db_revenue,
    ROUND(SUM(CASE WHEN dpd BETWEEN 180 AND 209 THEN co_value ELSE 0 END), 2) AS db_gaco,
    ROUND(SUM(ff_coll + lf_coll
              - CASE WHEN dpd BETWEEN 180 AND 209 THEN co_value ELSE 0 END), 2) AS db_nibt
FROM enriched
WHERE report_month IS NOT NULL AND report_month >= '2025-11'
GROUP BY 1
ORDER BY 1 DESC
""")

np11 = {r[0]: r[1:] for r in rows_np11}
db11 = {r[0]: r[1:] for r in rows_db11}
months11 = sorted(set(np11) | set(db11), reverse=True)

print()
hdr = f"{'month':<10}  {'np_rev':>12}  {'db_rev':>12}  {'rev_delta':>12}  {'np_gaco':>12}  {'db_gaco':>12}  {'gaco_delta':>12}  {'np_nibt':>12}  {'db_nibt':>12}  {'nibt_delta':>12}"
print(hdr)
print("-" * len(hdr))
for m in months11:
    np_r, np_g, np_n = np11.get(m, (0, 0, 0))
    db_r, db_g, db_n = db11.get(m, (0, 0, 0))
    print(f"{m:<10}  {np_r:>12,.0f}  {db_r:>12,.0f}  {(np_r-db_r):>+12,.0f}  "
          f"{np_g:>12,.0f}  {db_g:>12,.0f}  {(np_g-db_g):>+12,.0f}  "
          f"{np_n:>12,.0f}  {db_n:>12,.0f}  {(np_n-db_n):>+12,.0f}")

# Isolate the F&F exclusion effect on revenue (separate from cascade)
print("\n-- Isolating F&F impact on revenue (dashboard cascade, with vs without exclusion) --")
cols_ff, rows_ff = run(f"""
WITH bg AS (
    SELECT
        lt.business_id, lt.snap_date,
        MAX(lt.days_past_due)                      AS dpd,
        SUM(lt.principal_balance_outstanding)      AS pbo,
        SUM(lt.factor_fee_amount_paid_last_month)  AS ff_coll,
        SUM(lt.fee_amount_paid_last_month)         AS lf_coll,
        SUM(lt.gross_principal_amount_charged_off) AS gaco,
        CASE
            WHEN x.business_id IS NOT NULL THEN 'F&F'
            ELSE 'non-F&F'
        END AS ff_flag
    FROM PROD_DB.DATA.LOAN_TAPE lt
    LEFT JOIN ({EXCL}) x ON x.business_id = lt.business_id
    WHERE DAY(lt.snap_date) = 1
    GROUP BY lt.business_id, lt.snap_date, x.business_id
)
SELECT
    TO_CHAR(snap_date - 1, 'YYYY-MM')     AS report_month,
    ff_flag,
    COUNT(DISTINCT business_id)            AS business_count,
    ROUND(SUM(ff_coll + lf_coll), 2)      AS revenue
FROM bg
WHERE TO_CHAR(snap_date - 1, 'YYYY-MM') >= '2025-11'
GROUP BY 1, 2
ORDER BY 1 DESC, 2
""")
pt(cols_ff, rows_ff, indent=2)

conn.close()
print("\n\nDone.")
