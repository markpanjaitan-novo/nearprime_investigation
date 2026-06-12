# nearprime_investigation — Claude Context
## AGENT INSTRUCTIONS

You are an expert of credit card product and business analysis.

## CRITICAL: Banned table

**NEVER use `FIVETRAN_DB.PROD_NOVO_API_PUBLIC.CREDIT_CARD_APPLICATION_DECISIONS`.**
This table has multi-row fan-out per application and must not appear in any query, CTE, or join.

Canonical replacements:
- **Booking date / booking timestamp** → `CREDIT_CARD_ACCOUNTS.created_at` (account creation ≈ approval date; this table only contains approved/opened accounts)
- **Approval filter** → `CREDIT_CARD_APPLICATIONS.status = 'APPROVED'` instead of `decisions.decision = 'APPROVED'`
- **`_fivetran_deleted` guard** when joining CREDIT_CARD_ACCOUNTS → always add `coalesce(_fivetran_deleted, false) = false`

There is no replacement for `decision_notes` (manual review classification). Any query relying on that column must be commented out with an explanation until an alternative source is identified.

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
| `PROD_DB` | `ADHOC` | Monitoring views and lookup tables (BI_ROLE may lack access to some) |

**F&F exclusion — apply to every query:**
```sql
business_id not in (
    select business_id from FIVETRAN_DB.PROD_NOVO_API_PUBLIC.BUSINESS_GROUP_ASSIGNMENTS
    where business_group_id = '75fe98d2-6549-46a1-aa04-a1c621e21d9e'
)
```

## Data model

```
CREDIT_CARD_APPLICATIONS
    → CREDIT_CARD_APPLICATION_DECISIONS  (join on application_id)
    → CREDIT_CARD_ACCOUNTS               (shared business_id;
                                          accounts.external_account_id = loan_tape.account_id)
        → CREDIT_CARD_ACCOUNT_LOAN_TAPE_HISTORY      (account_id)
        → CREDIT_CARD_STATEMENTS                     (credit_card_account_id / business_id)
        → CREDIT_CARD_PAYMENTS                       (credit_card_account_id / business_id)
        → CREDIT_CARD_TRANSACTIONS                   (business_id)
        → CREDIT_CARD_AUTOPAY_INSTRUCTIONS           (credit_card_account_id / business_id)
        → CREDIT_CARD_NOVO_SETTLEMENT_REPORT_ITEMS   (credit_card_account_id = accounts.id)
        → CREDIT_CARD_TRANSACTION_REWARD_ITEMS       (credit_card_account_id = accounts.id)
        → CREDIT_CARD_REWARD_REDEMPTIONS             (credit_card_account_id = accounts.id)
        → CREDIT_CARD_ACCOUNT_REWARDS                (credit_card_account_id = accounts.id)
        → CREDIT_CARD_TRANSACTION_DISPUTES           (business_id)

CREDIT_CARD_INVITATIONS  (business_id) — FICO score source (pre-approval, not refreshed)
CREDIT_CARDS             (business_id) — physical/virtual card records; activation status
BUSINESS_GROUP_ASSIGNMENTS (business_id) — F&F / internal test account exclusion list
PROD_DB.ADHOC.MONITOR_RISK_BUCKET_LOOKUP (business_id) — risk bucket and campaign tagging
```

## Table reference

### `PROD_DB.DATA.CREDIT_CARD_ACCOUNT_LOAN_TAPE_HISTORY` — the core risk table

- **Grain: DAILY APPEND table** — one row per calendar day per billing period per account. The table is not a period-end snapshot; it appends a new row every day as that day's state is finalized. ~8,210 distinct accounts; data from Oct 2024 → present
- **All money columns are in cents — divide by 100 everywhere**
- `billing_period_number = 0` is the booking-month statement (often excluded with `>= 1`)
- **Getting the period-end snapshot** (for ADB, ending balance, etc.): select the last row of the period using `ORDER BY statement_date DESC, record_version DESC` within `PARTITION BY billing_period_number`:
  ```sql
  qualify row_number() over (
      partition by ca.business_id, lt.billing_period_number
      order by lt.statement_date desc, lt.record_version desc
  ) = 1
  ```
  **WARNING: `ORDER BY record_version DESC` alone is wrong.** `record_version` marks amendments to a specific day — a mid-period day can receive a `record_version=2` amendment, making it the highest record_version in the partition even though it is not the last day of the period. This causes ADB to be read from mid-period (grossly understated — verified 12× understatement on one account). Always sort by `statement_date DESC` first.
- **Production alternative pattern** (used in `28_cc_card_adoption_active_balance.sql`, `30_vintage_driver.sql`): deduplicate per day first (`PARTITION BY (business_id, statement_date) ORDER BY record_version DESC`), then filter to period-end using `day(statement_date) = 1` or a `last_day()` subquery. Both approaches are equivalent; the single-step pattern above is simpler for per-period analysis.
- Two patterns for month-end snapshot filtering — both are used in different query types:
  - **Calendar-month queries** (DPD buckets, roll rate): `day(statement_date) = 1` selects the 1st of the next month; pair with `to_char(statement_date-1, 'YYYY-MM')` to label the correct report month
  - **Booking-vintage queries**: `statement_date in (select distinct last_day(statement_date) from ...)` selects the last day of each billing month; pair with `to_char(statement_date, 'YYYY-MM')`
  - These select **different calendar dates** — do not mix the two patterns in a single query
- **`business_id` is NOT a column on this table.** To get `business_id`, always join to `CREDIT_CARD_ACCOUNTS`:
  ```sql
  from PROD_DB.DATA.CREDIT_CARD_ACCOUNT_LOAN_TAPE_HISTORY lt
  join FIVETRAN_DB.PROD_NOVO_API_PUBLIC.CREDIT_CARD_ACCOUNTS ca
      on ca.external_account_id = lt.account_id
  ```
  Then use `ca.business_id` everywhere. Referencing `lt.business_id` will throw `invalid identifier`.

| Column | Notes |
|---|---|
| `days_past_due` | 0=current, 1–29/30–59/60–89/90–179=DQ buckets, 180–210=chargeoff transition, >210=post-CO |
| `billing_period_number` | Statement cycle counter. 0 = booking month |
| `ending_balance` | Total balance at statement close (cents) |
| `credit_limit` | Approved limit (cents) |
| `next_due_principal + past_statements_principal + due_principal + past_due_principal` | **4-slice principal sum** — total principal owed; used for chargeoff $ |
| `payment_allocated_principal / interest / fees` | Payments received that period by component (cents) |
| `effective_apr_purchases` | Purchase APR in effect |
| `grace_period` | Boolean — TRUE means paid in full last cycle, no interest accruing. Compare as `= false` (not the string `'false'`) |
| `record_version` | Amendment counter scoped to a specific `(account_id, statement_date)` — NOT a period-level version. Higher = more recent amendment for that specific day. Mid-period days can receive amendments (record_version=2+); last day of period almost always stays at record_version=1. |
| `starting_balance` / `ending_balance` | Period open/close balances |
| `daily_balance_purchases` | **Running cumulative ADB for purchase balance** — on day N of the billing period it equals `sum(ending_balance[days 1..N]) / N`. Only the last day's row contains the final ADB for that period. **Stored as TEXT** in Snowflake; cast explicitly: `daily_balance_purchases::number / 100`. Reading this column from a mid-period row gives an incorrect (understated) ADB. |
| `day_purchases` | Purchase amount transacted on that specific day (NUMBER, cents). Distinct from `daily_balance_purchases`. Used for purchase volume in vintage analysis |
| `period_payments` | Total payments received during the billing period (NUMBER, cents, negative sign). Used in min-pay ratio vintage queries |

### `CREDIT_CARD_ACCOUNTS`

- `external_account_id` = join key to loan tape `account_id`
- `id` = join key for settlement report and reward items
- `_fivetran_deleted` is NULL (not false) for live records — omit the filter or use `coalesce(_fivetran_deleted, false) = false`
- `status` / `external_status` — account lifecycle; `is_account_in_collection` boolean

### `CREDIT_CARD_APPLICATIONS` + `CREDIT_CARD_APPLICATION_DECISIONS`

- 8,217 approved, 347 denied; Oct 2024 → present
- Join: `decisions.application_id = applications.id`
- `decisions.created_at` = approval timestamp — used as booking date in vintage analysis
- `approved_credit_limit`, `approved_apr`, `rejected_reasons` (VARIANT array) live on decisions

### `CREDIT_CARD_STATEMENTS`

- `start_date` / `end_date` = billing window; `payment_due_date` = payment deadline
- `statement_balance`, `minimum_payment_due`, `purchases` in cents
- `purchases` — total purchase volume billed in this statement cycle (NUMBER, cents)
- Cashback columns (all cents):

| Column | Notes |
|---|---|
| `earned_cashback` | Cashback earned this statement cycle |
| `redeemed_cashback` | Cashback redeemed (withdrawn) this statement cycle |
| `available_cashback` | Balance available to redeem at statement close |
| `total_earned_cashback` | Lifetime earned cumulative |
| `total_redeemed_cashback` | Lifetime redeemed cumulative |

As of Jun 2026: 2,887 statements have `redeemed_cashback > 0`; $276K total redeemed at statement level. For event-level redemption detail use `CREDIT_CARD_REWARD_REDEMPTIONS` instead.

### `CREDIT_CARD_PAYMENTS`

- Statuses: `settled` (90K), `failed` (11K), `returned` (197), `cancelled`, `pending`
- Only use `status = 'settled'` for collection/revenue analysis
- `autopay_instruction_id` — non-null = autopay-triggered payment
- `option` — payment option chosen (minimum, full, custom)

### `CREDIT_CARD_TRANSACTIONS`

- 516K settled/approved; 79K declined
- Use `status = 'settled' AND result = 'APPROVED'` for purchase volume
- `settled_amount` in cents; `merchant_category_code` for spend categorisation

### `CREDIT_CARD_AUTOPAY_INSTRUCTIONS`

| Type | Active | Inactive |
|---|---|---|
| `statement_balance` | 1,181 | 528 |
| `minimum_due` | 1,070 | 575 |
| `fixed_amount` | 142 | 241 |

- No business ever has >1 active instruction simultaneously (verified)
- Launched Oct 2024; full history available
- **Point-in-time enrollment** for month M:
  ```sql
  created_at::date <= last_day(M)
  and (status = 'active' or updated_at::date > last_day(M))
  ```
  `updated_at` = effective cancellation date for inactive instructions

### `CREDIT_CARD_NOVO_SETTLEMENT_REPORT_ITEMS`

- One row per account per settlement report (daily cadence)
- `interchange_gross_amount` — **negative cents** (revenue to Novo). Use `* -1 / 100`
- Join: `credit_card_account_id = CREDIT_CARD_ACCOUNTS.id`

### `CREDIT_CARD_TRANSACTION_REWARD_ITEMS`

- `rewards` — cashback accrued per transaction, **positive cents**. Use `/ 100`
- `is_available` — `TRUE` = reward is still available to redeem; `FALSE` = reward has been consumed by a redemption
  - 439K rows `is_available = TRUE` (~$577K accrued); 25K rows `is_available = FALSE` (~$35K consumed)
- Join: `credit_card_account_id = CREDIT_CARD_ACCOUNTS.id`
- This table tracks **accrual** (earn events). For **redemption** events use `CREDIT_CARD_REWARD_REDEMPTIONS`.

### `CREDIT_CARD_REWARD_REDEMPTIONS`

**Use this table to track when customers actually redeem (spend) their cashback.**

- One row per redemption event — cash is deposited into the customer's DDA account
- 3,116 rows, all `status = 'success'`; $308,504 total redeemed to date (Jun 2026)
- Join: `credit_card_account_id = CREDIT_CARD_ACCOUNTS.id`

| Column | Notes |
|---|---|
| `credit_card_account_id` | Join to `CREDIT_CARD_ACCOUNTS.id` |
| `rewards` | Amount redeemed in **cents** (÷100 for dollars) |
| `status` | Only `'success'` observed — no pending/failed rows |
| `posted_at` | Timestamp cash settled to DDA — use this for monthly grouping |
| `created_at` | Timestamp redemption was initiated |
| `transaction_id` | Links to the DDA `TRANSACTIONS` table (the cash deposited) |
| `user_id` | User who triggered the redemption |
| `trace_number` | ACH trace ID (format: `NCCRxxxxxxxxxx`) |

**Monthly redemption query:**
```sql
select
     to_char(r.posted_at, 'YYYY-MM')             as redeem_month
    ,count(distinct r.credit_card_account_id)     as accounts_redeemed
    ,count(*)                                      as redemption_events
    ,round(sum(r.rewards) / 100.0, 2)             as total_redeemed_dollars
from FIVETRAN_DB.PROD_NOVO_API_PUBLIC.CREDIT_CARD_REWARD_REDEMPTIONS r
join FIVETRAN_DB.PROD_NOVO_API_PUBLIC.CREDIT_CARD_ACCOUNTS a
    on a.id = r.credit_card_account_id
where coalesce(a._fivetran_deleted, false) = false
  and r.status = 'success'
  and a.business_id not in (
      select business_id from FIVETRAN_DB.PROD_NOVO_API_PUBLIC.BUSINESS_GROUP_ASSIGNMENTS
      where business_group_id = '75fe98d2-6549-46a1-aa04-a1c621e21d9e'
  )
group by 1
order by 1
```

### `CREDIT_CARD_ACCOUNT_REWARDS`

- Current-state reward balance per account (one row per account, not historical)
- Join: `credit_card_account_id = CREDIT_CARD_ACCOUNTS.id`
- All amounts in cents

| Column | Notes |
|---|---|
| `pending_rewards` | Earned but not yet settled |
| `available_rewards` | Available to redeem now |
| `redeemed_rewards` | Lifetime redeemed total |

Use this for a point-in-time snapshot of unspent reward balances across the portfolio. For event history use `CREDIT_CARD_REWARD_REDEMPTIONS`.

### `CREDIT_CARD_TRANSACTION_DISPUTES`

- 1,175 accepted, 437 rejected; all `type = 'customer'`
- `amount` in cents; use `status = 'accepted'` for purchase fraud cost
- `approved_dispute_amount` = final accepted amount

### `CREDIT_CARD_INVITATIONS`

- FICO score range: 581–850; avg ~769
- Pre-approval score only — not refreshed post-booking
- Always take the most recent: `row_number() over (partition by business_id order by created_at desc) = 1`

### `CREDIT_CARDS`

- One row per card issued (physical or virtual) per account; a business can have multiple rows
- Join: `business_id` to `CREDIT_CARD_ACCOUNTS.business_id`
- Dedup to latest physical card: `type = 'physical'` + `row_number() over (partition by business_id order by created_at desc) = 1`
- `is_activated` (BOOLEAN) — TRUE once the cardholder has activated the physical card
- Used for activation-rate reporting by booking vintage and FICO band

### `PROD_DB.ADHOC.MONITOR_RISK_BUCKET_LOOKUP`

- Maps `business_id` → `risk_bucket` and `campaign` for vintage segmentation
- Used in the monitoring dashboard vintage driver (`30_vintage_driver.sql`)
- Note: BI_ROLE may not have access from all connection contexts

## Universal business logic

### DPD bucket convention

| Range | Label |
|---|---|
| 0 | Current |
| 1–29 | Bucket 1 |
| 30–59 | Bucket 2 |
| 60–89 | Bucket 3 |
| 90–119 | Bucket 4 |
| 120–149 | Bucket 5 |
| 150–179 | Bucket 6 |
| 180–210 | Bucket 7 / Chargeoff transition |
| >210 | Post-CO / out of scope |

### Chargeoff recognition

- Triggered when `days_past_due BETWEEN 180 AND 210` at month-end statement
- **CO dollar amount depends on context — two definitions are used:**
  - **NACO rate / CO vintage queries** (`cum co unit`, `cum co dollar`, `co unit non-cum`): use `ending_balance / 100` — the full balance written off the books, including accrued interest and fees. This is the regulatory/accounting standard and is consistent with the `ending_balance` denominator used in the NACO rate.
  - **NIBT CO component** (`cum nibt`, `nibt non-cum`, monthly `nibt`): use the 4-slice principal sum `(next_due_principal + past_statements_principal + due_principal + past_due_principal) / 100` — avoids double-counting because accrued interest/fees were never recognised as revenue in NIBT.
- Take first crossing only to avoid double-counting:
  ```sql
  qualify row_number() over (partition by account_id order by statement_date asc) = 1
  ```

### Cohort-matched NACO

- Gross CO = principal at first DPD 180–210 crossing
- Recovery = `payment_allocated_principal` in months strictly after `co_month` for those same accounts
- Net CO = gross CO − cumulative recovery
- Rate denominator = `(prior_month_ending_balance + current_ending_balance) / 2`
- Annualise by multiplying monthly rate × 12

### Amount handling

- **Every monetary field across all tables is stored in cents**
- Divide by 100 for dollars
- Interchange and rewards are stored as negative — multiply by −1 before dividing

### Cure rate

- Delinquent = `days_past_due BETWEEN 1 AND 179` at month-end
- Cured = same account at `days_past_due = 0` the following month-end
- Rolled to CO = `days_past_due >= 180` the following month — not a cure

### Revenue vs. NIBT — two distinct metrics

**Revenue per account** (used in `may_2026_cc_metrics.sql`):
```
Revenue = Interchange + Interest collected + Fees collected
```
Rewards are **not** revenue — they are a cost paid to the customer and must not be included here.

- Interchange: `sum(interchange_gross_amount * -1 / 100.0)` from `CREDIT_CARD_NOVO_SETTLEMENT_REPORT_ITEMS`
- Interest collected: `payment_allocated_interest / 100.0` from loan tape at month-end statement
- Fees collected: `payment_allocated_fees / 100.0` from loan tape at month-end statement

**NIBT** (used in `30_vintage_driver.sql` — cumulative per vintage cohort):
```
NIBT = Interchange + Interest collected + Fees collected − Rewards accrued − Chargeoffs − Purchase fraud
```
Rewards here are accrual-based (cashback earned on transactions), sourced from `CREDIT_CARD_TRANSACTION_REWARD_ITEMS.rewards` (negative cents). The vintage driver CTE is named `reward_redemption` but queries the **accrual** table, not `CREDIT_CARD_REWARD_REDEMPTIONS`.

Do not confuse the two rewards tables:
- `CREDIT_CARD_TRANSACTION_REWARD_ITEMS` — cashback **earned** per transaction (accrual). Used in NIBT cost calculation.
- `CREDIT_CARD_REWARD_REDEMPTIONS` — cashback **paid out** to the customer's DDA (cash event). Used for redemption tracking only.

## DDA (checking account) tables

These two tables cover the Novo DDA (demand deposit / checking) product. Nearly all CC customers (~8,186 of ~8,210) also have a DDA account. Both join to the CC world via `business_id`.

### `PROD_DB.DATA.BALANCES_DAILY`

- **Grain:** one row per `(business_id, date)` — verified no duplicates
- 400M+ rows; data from Aug 2018 → present
- Three columns only:

| Column | Notes |
|---|---|
| `business_id` | Join key to all CC tables |
| `date` | Calendar date of the balance snapshot |
| `day_end_balance` | End-of-day DDA balance in **dollars** (not cents — unlike CC tables) |

Typical usage:
```sql
-- Daily balance for CC customers
select b.date, b.day_end_balance
from PROD_DB.DATA.BALANCES_DAILY b
join FIVETRAN_DB.PROD_NOVO_API_PUBLIC.CREDIT_CARD_ACCOUNTS cc
    on cc.business_id = b.business_id
where b.date = '2026-05-31'
```

### `PROD_DB.DATA.TRANSACTIONS`

- **Grain:** one row per transaction (`transaction_id`)
- 97M+ rows; data from Dec 2017 → present
- Amounts in **dollars** (not cents). Positive = inflow, negative = outflow
- Use `status = 'active'` for settled transactions (rejects are ~1M rows)

**Key columns:**

| Column | Notes |
|---|---|
| `transaction_id` | Primary key |
| `business_id` | Join key to CC tables |
| `account_id` | DDA account identifier |
| `amount` | Dollars. Positive = inflow (credit), negative = outflow (debit) |
| `type` | `credit` (inflows, 29M rows) or `debit` (outflows, 68M rows) |
| `status` | `active` (95M), `rejected` (1M), `pending` (290K). Use `active` for analysis |
| `medium` | Transaction channel — see breakdown below |
| `created_date` | Date transaction was created |
| `posted_date` | Date transaction posted |
| `effective_date` | Value date |
| `running_balance` | Account balance after this transaction |
| `category` / `supercategory` | Spend categorisation |
| `merchant_category_code` | MCC for card transactions |
| `card_revenue` | Interchange revenue on debit card transactions |
| `short_description` | Cleaned merchant/payee name |

**`medium` breakdown (top values):**

| Medium | Count | Direction |
|---|---|---|
| POS Withdrawal | 44.7M | outflow — debit card purchases |
| External Deposit | 20.8M | inflow — ACH / external transfers in |
| External Withdrawal | 15.2M | outflow — ACH / external transfers out |
| Withdrawal | 6.1M | outflow — various |
| EFT Credit | 3.1M | inflow |
| Deposit | 3.0M | inflow — direct deposits |
| ATM Withdrawal | 1.1M | outflow |
| Check | 458K | mixed |
| Domestic Wire Deposit | 167K | inflow |

**Joining to credit businesses:**
```sql
-- DDA transaction activity for CC cardholders
from FIVETRAN_DB.PROD_NOVO_API_PUBLIC.CREDIT_CARD_ACCOUNTS cc
join PROD_DB.DATA.TRANSACTIONS t
    on t.business_id = cc.business_id
   and t.status = 'active'
where cc.business_id not in (
    select business_id from FIVETRAN_DB.PROD_NOVO_API_PUBLIC.BUSINESS_GROUP_ASSIGNMENTS
    where business_group_id = '75fe98d2-6549-46a1-aa04-a1c621e21d9e'
)
```

**Important:** DDA amounts are in **dollars** — no /100 needed, unlike all CC loan tape fields.

**Gotcha:** `PROD_DB.DATA.TRANSACTIONS` does NOT have a `created_at` column. Use `created_date` (DATE) for monthly bucketing: `to_char(t.created_date, 'YYYY-MM')`. Also available: `posted_date`, `effective_date`, `transaction_date` (TIMESTAMP_TZ).

### Joining DDA + CC for a single account

```sql
with acct as (
    select '<business_id>' as business_id
)
-- DDA balance
select to_char(b.date, 'YYYY-MM') as report_mth, avg(b.day_end_balance) as avg_daily_balance
from acct a
join PROD_DB.DATA.BALANCES_DAILY b on b.business_id = a.business_id
group by 1

-- DDA transactions
select to_char(t.created_date, 'YYYY-MM') as report_mth,
       sum(case when t.amount > 0 then t.amount else 0 end) as inflow,
       sum(case when t.amount < 0 then -t.amount else 0 end) as outflow
from acct a
join PROD_DB.DATA.TRANSACTIONS t on t.business_id = a.business_id
where t.status = 'active'
group by 1
```

### Finding individual accounts for investigation

Use this pattern to pull a shortlist of accounts matching FICO band, booking window, and activity criteria:

```sql
with inv as (
    select business_id, fico_score
    from FIVETRAN_DB.PROD_NOVO_API_PUBLIC.CREDIT_CARD_INVITATIONS
    qualify row_number() over (partition by business_id order by created_at desc) = 1
),
booking as (
    select b.business_id, min(d.created_at)::date as booking_date
    from FIVETRAN_DB.PROD_NOVO_API_PUBLIC.CREDIT_CARD_APPLICATIONS a
    join FIVETRAN_DB.PROD_NOVO_API_PUBLIC.CREDIT_CARD_APPLICATION_DECISIONS d
        on d.application_id = a.id and d.decision = 'APPROVED'
    join FIVETRAN_DB.PROD_NOVO_API_PUBLIC.CREDIT_CARD_ACCOUNTS b on b.business_id = a.business_id
    group by 1
),
stmt_count as (
    select b.business_id,
           count(distinct a.statement_date) as stmt_count,
           max(a.days_past_due)             as max_dpd
    from PROD_DB.DATA.CREDIT_CARD_ACCOUNT_LOAN_TAPE_HISTORY a
    join FIVETRAN_DB.PROD_NOVO_API_PUBLIC.CREDIT_CARD_ACCOUNTS b on a.account_id = b.external_account_id
    where a.billing_period_number >= 1
    group by 1
)
select bk.business_id, bk.booking_date, inv.fico_score, sc.stmt_count, sc.max_dpd
from booking bk
join inv        on inv.business_id = bk.business_id
join stmt_count sc on sc.business_id = bk.business_id
-- optionally join active_may to filter to still-active accounts
where inv.fico_score between 660 and 719          -- ← adjust FICO band
  and bk.booking_date between '2024-10-01' and '2025-12-31'
  and bk.business_id not in (
      select business_id from FIVETRAN_DB.PROD_NOVO_API_PUBLIC.BUSINESS_GROUP_ASSIGNMENTS
      where business_group_id = '75fe98d2-6549-46a1-aa04-a1c621e21d9e'
  )
order by sc.max_dpd desc, sc.stmt_count desc
```

## SQL files in this directory

| File | Purpose |
|---|---|
| `cc_chargeoff_rate_by_month.sql` | Cohort-matched NACO: gross CO, recoveries, net CO rate by chargeoff month |
| `cc_recovery_validation.sql` | Step-by-step account-level validation of chargeoff + recovery flow |
| `may_2026_cc_metrics.sql` | Monthly CC metrics: NCO rate, repayment rate, autopay enrollment, cure rate, active card counts, application IDs |
| `nearprime_account_investigation.sql` | FICO 660-719 cohort: DDA behavior + CC performance by month; individual account drilldown (Q3/Q4) |
| `Compliance.sql` | Application IDs Apr–May 27 2026 |
| `cc_vintage_snapshot.sql` | Vintage-level snapshot of credit card cohorts |
| `outstanding_balance_vs_ar_comparison.sql` | Compares outstanding balance vs AR across DPD buckets |
| `monitoring.sql` | Ad-hoc monitoring queries |
| `explore.sql` | Exploratory / scratch queries |
