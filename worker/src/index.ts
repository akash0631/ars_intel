// ARS Intel API — Cloudflare Worker
// Hono router proxying read-only Snowflake queries against V2RETAIL.ARS_GOLD.

import { Hono } from "hono";
import { cors } from "hono/cors";
import { executeQuery, type SnowflakeEnv, type SnowflakeBinding } from "./snowflake";

type Env = SnowflakeEnv;

const app = new Hono<{ Bindings: Env }>();

app.use("*", cors({
  origin: "*",
  allowMethods: ["GET", "POST", "OPTIONS"],
  allowHeaders: ["Content-Type", "Authorization"],
  maxAge: 86400,
}));

// ---------------------------------------------------------------------------
// Health
// ---------------------------------------------------------------------------
app.get("/api/health", (c) => c.json({ ok: true, ts: new Date().toISOString() }));

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------
function bindText(value: string): SnowflakeBinding { return { type: "TEXT", value }; }
function bindNum(value: number): SnowflakeBinding  { return { type: "FIXED", value: String(value) }; }
function bindDate(value: string): SnowflakeBinding { return { type: "DATE", value }; }

function clampInt(raw: string | undefined, def: number, min: number, max: number): number {
  const n = Number.parseInt(raw ?? "", 10);
  if (!Number.isFinite(n)) return def;
  return Math.min(max, Math.max(min, n));
}

function isYmd(s: string | undefined): s is string {
  return !!s && /^\d{4}-\d{2}-\d{2}$/.test(s);
}

// ---------------------------------------------------------------------------
// GET /api/alerts/top?limit=20&run_date=YYYY-MM-DD
// ---------------------------------------------------------------------------
app.get("/api/alerts/top", async (c) => {
  const env = c.env;
  const limit = clampInt(c.req.query("limit"), 20, 1, 500);
  const runDate = c.req.query("run_date");

  const where = isYmd(runDate) ? `WHERE RUN_DATE = TO_DATE(:run_date)` : "";
  const bindings: Record<string, SnowflakeBinding> = {
    limit: bindNum(limit),
  };
  if (isYmd(runDate)) bindings["run_date"] = bindDate(runDate);

  const sql = `
    SELECT *
    FROM V2RETAIL.ARS_GOLD.MART_ALERTS_TOP
    ${where}
    ORDER BY RUN_DATE DESC, SEVERITY_RANK ASC NULLS LAST, SEVERITY DESC NULLS LAST
    LIMIT :limit
  `;

  try {
    const out = await executeQuery(env, sql, bindings);
    return c.json({ ok: true, rowCount: out.rowCount, rows: out.rows });
  } catch (e: unknown) {
    const msg = e instanceof Error ? e.message : String(e);
    return c.json({ ok: false, error: msg }, 500);
  }
});

// ---------------------------------------------------------------------------
// GET /api/alerts/trends?days=30
// ---------------------------------------------------------------------------
app.get("/api/alerts/trends", async (c) => {
  const env = c.env;
  const days = clampInt(c.req.query("days"), 30, 1, 365);

  const sql = `
    SELECT *
    FROM V2RETAIL.ARS_GOLD.MART_DAILY_ROLLUP
    WHERE RUN_DATE >= DATEADD(day, -:days, CURRENT_DATE())
    ORDER BY RUN_DATE ASC
  `;

  try {
    const out = await executeQuery(env, sql, { days: bindNum(days) });
    return c.json({ ok: true, rowCount: out.rowCount, rows: out.rows });
  } catch (e: unknown) {
    const msg = e instanceof Error ? e.message : String(e);
    return c.json({ ok: false, error: msg }, 500);
  }
});

// ---------------------------------------------------------------------------
// GET /api/drill/sessions?run_date=YYYY-MM-DD
// distinct SESSION_ID + status from V_SILVER_SESSIONS
// ---------------------------------------------------------------------------
app.get("/api/drill/sessions", async (c) => {
  const env = c.env;
  const runDate = c.req.query("run_date");

  const where = isYmd(runDate) ? `WHERE RUN_DATE = TO_DATE(:run_date)` : "";
  const bindings: Record<string, SnowflakeBinding> = {};
  if (isYmd(runDate)) bindings["run_date"] = bindDate(runDate);

  const sql = `
    SELECT DISTINCT
      SESSION_ID,
      STATUS,
      RUN_DATE,
      ANY_VALUE(STARTED_AT) AS STARTED_AT,
      ANY_VALUE(FINISHED_AT) AS FINISHED_AT
    FROM V2RETAIL.ARS_GOLD.V_SILVER_SESSIONS
    ${where}
    GROUP BY SESSION_ID, STATUS, RUN_DATE
    ORDER BY RUN_DATE DESC, SESSION_ID DESC
    LIMIT 500
  `;

  try {
    const out = await executeQuery(env, sql, bindings);
    return c.json({ ok: true, rowCount: out.rowCount, rows: out.rows });
  } catch (e: unknown) {
    const msg = e instanceof Error ? e.message : String(e);
    return c.json({ ok: false, error: msg }, 500);
  }
});

// ---------------------------------------------------------------------------
// GET /api/drill/store-majcat?session_id=&maj_cat=&store=
// MART_DRILL_SESSION filtered
// ---------------------------------------------------------------------------
app.get("/api/drill/store-majcat", async (c) => {
  const env = c.env;
  const sessionId = c.req.query("session_id");
  const majCat    = c.req.query("maj_cat");
  const store     = c.req.query("store");

  if (!sessionId) {
    return c.json({ ok: false, error: "session_id required" }, 400);
  }

  const filters: string[] = ["SESSION_ID = :session_id"];
  const bindings: Record<string, SnowflakeBinding> = {
    session_id: bindText(sessionId),
  };
  if (majCat) {
    filters.push("MAJ_CAT = :maj_cat");
    bindings["maj_cat"] = bindText(majCat);
  }
  if (store) {
    filters.push("STORE = :store");
    bindings["store"] = bindText(store);
  }

  const sql = `
    SELECT *
    FROM V2RETAIL.ARS_GOLD.MART_DRILL_SESSION
    WHERE ${filters.join(" AND ")}
    ORDER BY STORE, MAJ_CAT
    LIMIT 5000
  `;

  try {
    const out = await executeQuery(env, sql, bindings);
    return c.json({ ok: true, rowCount: out.rowCount, rows: out.rows });
  } catch (e: unknown) {
    const msg = e instanceof Error ? e.message : String(e);
    return c.json({ ok: false, error: msg }, 500);
  }
});

// ---------------------------------------------------------------------------
// 404
// ---------------------------------------------------------------------------
app.notFound((c) => c.json({ ok: false, error: "not_found" }, 404));

app.onError((err, c) => {
  return c.json({ ok: false, error: err.message }, 500);
});

export default app;
