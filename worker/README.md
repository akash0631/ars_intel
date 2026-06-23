# ars-intel-api

Cloudflare Worker that proxies read-only Snowflake queries from the ARS Intel UI to
`V2RETAIL.ARS_GOLD` using **key-pair JWT auth** (no passwords, no MFA prompts).

## Endpoints

| Method | Path                                                                | Source view / table                |
| ------ | ------------------------------------------------------------------- | ---------------------------------- |
| GET    | `/api/health`                                                       | —                                  |
| GET    | `/api/alerts/top?limit=20&run_date=YYYY-MM-DD`                      | `MART_ALERTS_TOP`                  |
| GET    | `/api/alerts/trends?days=30`                                        | `MART_DAILY_ROLLUP`                |
| GET    | `/api/drill/sessions?run_date=YYYY-MM-DD`                           | `V_SILVER_SESSIONS`                |
| GET    | `/api/drill/store-majcat?session_id=&maj_cat=&store=`               | `MART_DRILL_SESSION`               |

All responses: `{ ok: boolean, rowCount?, rows?, error? }`.

---

## 1. Generate RSA key-pair (one-time)

```bash
# 2048-bit unencrypted PKCS#8 — what Web Crypto can import
openssl genrsa 2048 \
  | openssl pkcs8 -topk8 -inform PEM -outform PEM -nocrypt -out rsa_key.p8

# Matching public key for Snowflake
openssl rsa -in rsa_key.p8 -pubout -out rsa_key.pub

# Fingerprint (Snowflake JWT claim needs SHA256:...)
openssl rsa -pubin -in rsa_key.pub -outform DER \
  | openssl dgst -sha256 -binary \
  | openssl enc -base64
# → paste output prefixed with "SHA256:" when setting the secret
```

> Snowflake fingerprint shown by `DESC USER` already includes the `SHA256:` prefix.

## 2. Register public key on Snowflake user

```sql
USE ROLE ACCOUNTADMIN;
ALTER USER AKASHV2KART
  SET RSA_PUBLIC_KEY = 'MIIBIjANBgkqhkiG9w0BAQEFA...';   -- single line, no PEM headers

-- Confirm fingerprint
DESC USER AKASHV2KART;
-- look for property RSA_PUBLIC_KEY_FP → SHA256:abcd...
```

User must already have:

- default role with `USAGE` on `WAREHOUSE ALLOC_WH`
- `USAGE` on `DATABASE V2RETAIL` and `SCHEMA V2RETAIL.ARS_GOLD`
- `SELECT` on the four sources above

## 3. Install + secrets

```bash
cd C:/Users/akash.agarwal/projects/ars_intel/worker
npm install

# Private key (paste the FULL PEM including BEGIN/END lines)
wrangler secret put SNOWFLAKE_PRIVATE_KEY

# Public-key fingerprint, e.g.  SHA256:abcd1234...
wrangler secret put SNOWFLAKE_PRIVATE_KEY_FP
```

Non-secret vars (account / user / wh / db / schema) already live in `wrangler.toml`.

## 4. Local dev

```bash
npm run dev
# then: curl http://127.0.0.1:8787/api/health
```

## 5. Deploy

```bash
npm run deploy
# default URL: https://ars-intel-api.<your-subdomain>.workers.dev
```

Bind a custom domain via CF dashboard (Workers → Triggers → Custom Domains) — e.g.
`ars-intel-api.v2retail.net` — and update the Pages `_redirects` accordingly.

## 6. Smoke test

```bash
curl https://ars-intel-api.<sub>.workers.dev/api/health
curl 'https://ars-intel-api.<sub>.workers.dev/api/alerts/top?limit=5'
curl 'https://ars-intel-api.<sub>.workers.dev/api/alerts/trends?days=14'
```

## Notes

- JWT is cached in worker memory for ~50 min (`SignedJwt.expiresAt - 600s`),
  refreshed lazily on the next request. No KV / D1 needed.
- Statements > 45s switch to async polling (`GET /api/v2/statements/<handle>`)
  with exponential backoff capped at 4s, total budget 60s.
- All query bindings use the SQL API's named-bind syntax (`:name`) — no string
  interpolation, no injection surface.
- Read-only by design: only `SELECT` against `ARS_GOLD` is proxied.
