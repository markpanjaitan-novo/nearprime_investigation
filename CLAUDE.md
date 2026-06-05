# nearprime_investigation — Claude Context

## Snowflake connection

This project queries Snowflake directly from the terminal using the Python connector.
**Do not attempt snowsql, externalbrowser, or PAT auth** — none of those work on this machine.

### How to connect

```python
import snowflake.connector, tomli as tomllib
from pathlib import Path

cfg = tomllib.loads(Path.home().joinpath(".snowflake/connections.toml").read_text())
profile = cfg["A6040307054171-BANK_NOVO_ENTERPRISE"]

conn = snowflake.connector.connect(
    account=profile["account"],
    user=profile["user"],
    authenticator=profile.get("authenticator"),  # OAUTH_AUTHORIZATION_CODE
    role="BI_ROLE",
    warehouse="COMPUTE_WH",
    database="PROD_DB",
    schema="ADHOC",
)
```

- **Auth method:** `OAUTH_AUTHORIZATION_CODE` — opens a browser window on first connect each session. The user must complete the login there. Subsequent queries in the same session reuse the token.
- **Warehouse:** `COMPUTE_WH` (not `BI_WH` — that does not exist)
- **Role:** `BI_ROLE`
- **tomli** is used instead of `tomllib` because the machine runs Python 3.9 (`tomllib` is 3.11+). `tomli` is already installed.

### Running a SQL file

```python
cur = conn.cursor()
cur.execute("USE WAREHOUSE COMPUTE_WH")  # set explicitly if warehouse wasn't passed to connect()
sql = Path("your_query.sql").read_text()
cur.execute(sql)
rows = cur.fetchall()
cols = [d[0] for d in cur.description]
```

### What doesn't work on this machine

| Method | Why it fails |
|---|---|
| `externalbrowser` | SAML error — SSO is not wired to the CLI auth path |
| `programmatic_access_token` (PAT) | Token always rejected |
| `snowsql` CLI | Not installed |
| `tomllib` (stdlib) | Python 3.9 — use `tomli` instead |
| `BI_WH` warehouse | Does not exist — use `COMPUTE_WH` |

## Key tables

All queries in this directory hit Snowflake production:

| Database | Schema | Notes |
|---|---|---|
| `PROD_DB` | `DATA` | Core loan tape, account history |
| `FIVETRAN_DB` | `PROD_NOVO_API_PUBLIC` | API replica — accounts, applications, transactions |

Excluded business group (internal/test accounts): `75fe98d2-6549-46a1-aa04-a1c621e21d9e`

## SQL files in this directory

| File | Purpose |
|---|---|
| `outstanding_balance_vs_ar_comparison.sql` | Compares Q1 outstanding balance vs Q2 AR across DPD 0–180; surfaces differences |
| `cc_recovery_validation.sql` | Per-account loan tape walkthrough for charge-off/recovery validation |
| `cc_chargeoff_rate_by_month.sql` | Monthly charge-off rate trends |
| `cc_vintage_snapshot.sql` | Vintage-level snapshot of credit card cohorts |
| `may_2026_cc_metrics.sql` | May 2026 credit card metric pull |
| `monitoring.sql` | Ad-hoc monitoring queries |
| `explore.sql` | Exploratory / scratch queries |
