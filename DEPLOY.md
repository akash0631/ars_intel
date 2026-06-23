# ars_intel — Deployment Runbook

End-to-end ship guide for the ars_intel rules-driven allocation gap detector.
Target environments:

| Layer       | Host                                                   |
| ----------- | ------------------------------------------------------ |
| Source      | SQL Server `arsdbpro` / db `Rep_Data` on `HOPC345`     |
| Warehouse   | Snowflake account `iafphkw-hh80816`, db `V2RETAIL`     |
| API         | Cloudflare Worker `ars-intel-api`                      |
| UI          | Cloudflare Pages (Next.js 14 static export)            |
| Scheduler   | Windows Task Scheduler on V2DC-ADDVERB (`.36`)         |

---

## Prerequisites

- Snowflake user `akashv2kart` with `USAGE` on warehouse `ALLOC_WH` and
  `OWNERSHIP` (or full DDL grants) on `V2RETAIL.ARS_BRONZE` and
  `V2RETAIL.ARS_GOLD`. `SELECT` on the four ARS_GOLD views the worker queries.
- GitHub account `akash0631` with push access to `akash0631/ars_intel`.
- Cloudflare account with API token scoped to: Workers Scripts: Edit,
  Pages: Edit, Account: Read.
- On the loader VM (V2DC-ADDVERB / `.36`): Python 3.11+, ODBC Driver 17 for
  SQL Server, network reach to both `HOPC345` and `iafphkw-hh80816.snowflakecomputing.com`.
- On your laptop: `node >= 20`, `npm`, `wrangler >= 3.90`, `openssl`, `snowsql`
  (only for one-shot DDL/rule SQL execution).

---

## Step 1 — Snowflake schemas + bronze tables

Run from the repo root with `snowsql`:

```bash
snowsql -a iafphkw-hh80816 -u akashv2kart -w ALLOC_WH -d V2RETAIL \
  -f sql/ddl/01_schemas.sql        \
  -f sql/ddl/02_bronze_tables.sql  \
  -f sql/ddl/03_silver_views.sql   \
  -f sql/ddl/04_mart_alerts.sql
```

Creates:

- `V2RETAIL.ARS_BRONZE` — 1:1 mirror of `arsdbpro/Rep_Data`
- `V2RETAIL.ARS_GOLD` — silver views + `MART_ALERTS` + `REPLICATION_WATERMARKS`

All DDL is `CREATE … IF NOT EXISTS` / `CREATE OR REPLACE`, so it is idempotent.

---

## Step 2 — RSA key-pair for the Worker

```bash
cd worker

openssl genrsa 2048 \
  | openssl pkcs8 -topk8 -inform PEM -outform PEM -nocrypt -out rsa_key.p8

openssl rsa -in rsa_key.p8 -pubout -out rsa_key.pub

# Fingerprint
openssl rsa -pubin -in rsa_key.pub -outform DER \
  | openssl dgst -sha256 -binary | openssl enc -base64
# -> prefix the result with "SHA256:" when storing
```

Register the public key on the Snowflake user (single-line, no PEM header):

```sql
USE ROLE ACCOUNTADMIN;
ALTER USER AKASHV2KART
  SET RSA_PUBLIC_KEY = '<paste base64 body of rsa_key.pub>';
DESC USER AKASHV2KART;   -- confirm RSA_PUBLIC_KEY_FP
```

Keep `rsa_key.p8` private. It will be uploaded to the worker as a secret in
Step 6. Do not commit either key to the repo.

---

## Step 3 — Initial full replication SQL Server -> Snowflake

On V2DC-ADDVERB:

```powershell
cd C:\Users\akash.agarwal\projects\ars_intel\replication
python -m venv .venv
.\.venv\Scripts\pip install -r requirements.txt

Copy-Item .env.example .env
# Edit .env and fill SQL_PASSWORD + SNOWFLAKE_PASSWORD

.\.venv\Scripts\python ars_replicate.py --full
```

Expected runtime: ~30 minutes for the first full load
(`ARS_LISTING_HISTORY` ~22M + `ARS_ALLOC_HISTORY` ~11.6M + `ARS_pend_alc`
~1.1M + masters). Watermarks are recorded into
`V2RETAIL.ARS_GOLD.REPLICATION_WATERMARKS` so subsequent `--incremental`
runs only pull deltas.

---

## Step 4 — Run rule SQLs to populate MART_ALERTS

Each rule is `DELETE … WHERE RULE_ID = 'Rn' AND SESSION_ID IN <scope>` followed
by an `INSERT … SELECT`. Safe to re-run. Order does not matter between rules
(each writes its own `RULE_ID` rows) but `SQL_RUN_ORDER.md` documents the
canonical sequence.

```bash
snowsql -a iafphkw-hh80816 -u akashv2kart -w ALLOC_WH -d V2RETAIL \
  -f sql/rules/R1_MSA_UNALLOC.sql           \
  -f sql/rules/R2_SIZE_MIX_DRIFT.sql        \
  -f sql/rules/R3_ATTR_MIX_DRIFT.sql        \
  -f sql/rules/R4_CAP_BIND.sql              \
  -f sql/rules/R5_DC_OOS_GAP.sql            \
  -f sql/rules/R7_HOLD_HEAVY.sql            \
  -f sql/rules/R8_BDC_PIPELINE_DEAD.sql     \
  -f sql/rules/R9_MAJCAT_REGRESSION.sql     \
  -f sql/rules/R10_STORE_STARVATION.sql
```

Sanity-check after run:

```sql
SELECT RULE_ID, COUNT(*) FROM V2RETAIL.ARS_GOLD.MART_ALERTS
GROUP BY RULE_ID ORDER BY RULE_ID;
```

---

## Step 5 — Build the consumption marts

```bash
snowsql -a iafphkw-hh80816 -u akashv2kart -w ALLOC_WH -d V2RETAIL \
  -f sql/marts/MART_ALERTS_TOP.sql    \
  -f sql/marts/MART_DAILY_ROLLUP.sql  \
  -f sql/marts/MART_DRILL_SESSION.sql
```

These are `CREATE OR REPLACE VIEW`, fully idempotent.

---

## Step 6 — Deploy the Cloudflare Worker

```bash
cd worker
npm install

# private key — paste the full PEM including BEGIN/END PRIVATE KEY lines
wrangler secret put SNOWFLAKE_PRIVATE_KEY < rsa_key.p8

# fingerprint, e.g. SHA256:abcd...
echo "SHA256:<base64-fingerprint>" | wrangler secret put SNOWFLAKE_PRIVATE_KEY_FP

npm run deploy
```

Smoke test:

```bash
curl https://ars-intel-api.<your-subdomain>.workers.dev/api/health
curl 'https://ars-intel-api.<your-subdomain>.workers.dev/api/alerts/top?limit=5'
```

Bind the custom domain `ars-intel-api.v2retail.net` from the Cloudflare
dashboard (Workers -> Triggers -> Custom Domains) so that the Pages
`_redirects` file resolves.

---

## Step 7 — Deploy the Next.js dashboard to Cloudflare Pages

```bash
cd web
npm install
npm run build

# Publish the static export
wrangler pages deploy out/ \
  --project-name ars-intel-web \
  --branch main
```

Verify in browser: open the Pages URL and confirm Today / Trends / Drill
pages render. The `_redirects` file routes `/api/*` to the worker.

---

## Step 8 — Schedule incremental replication

On V2DC-ADDVERB, register a Windows Task Scheduler job:

- **Name:** `ars_intel_replicate_incremental`
- **Trigger:** Daily, repeat every 30 minutes, indefinitely
- **Program:** `C:\Users\akash.agarwal\projects\ars_intel\replication\.venv\Scripts\python.exe`
- **Arguments:** `ars_replicate.py --incremental`
- **Start in:** `C:\Users\akash.agarwal\projects\ars_intel\replication`
- **Run whether user is logged on or not**, highest privileges, no parallel
  instances, kill after 1h.

Replication time on incremental: typically 30-90s.

Recommended companion: a second Task Scheduler job that re-runs rule SQLs +
mart views every 30 minutes (5 minutes after the replication job) via
`snowsql -f` against each file in `sql/rules/` then `sql/marts/`. See
`SQL_RUN_ORDER.md` for the script-friendly sequence.

---

## One-shot full bootstrap

From the repo root, after Step 2 and Step 3 prerequisites are in place:

```bash
make all
```

`Makefile` wraps every step above so a clean machine can deploy with a single
command.
