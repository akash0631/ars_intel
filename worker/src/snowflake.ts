// Snowflake SQL API v2 client (REST).
// Docs: https://docs.snowflake.com/en/developer-guide/sql-api/reference
//
// POST https://<account>.snowflakecomputing.com/api/v2/statements
//   Authorization: Bearer <JWT>
//   X-Snowflake-Authorization-Token-Type: KEYPAIR_JWT
//
// For statements that don't finish in ~45s, Snowflake returns 202 + statementHandle;
// we poll GET /api/v2/statements/<handle> until 200.

import { buildSnowflakeJwt, type SignedJwt } from "./jwt";

export interface SnowflakeEnv {
  SNOWFLAKE_ACCOUNT: string;
  SNOWFLAKE_USER: string;
  SNOWFLAKE_WAREHOUSE: string;
  SNOWFLAKE_DATABASE: string;
  SNOWFLAKE_SCHEMA: string;
  SNOWFLAKE_PRIVATE_KEY?: string;          // secret — for JWT keypair auth
  SNOWFLAKE_PRIVATE_KEY_FP?: string;       // secret — "SHA256:..."
  SNOWFLAKE_PAT?: string;                  // secret — programmatic access token (preferred)
}

export interface SnowflakeBinding {
  type: "TEXT" | "FIXED" | "REAL" | "BOOLEAN" | "DATE" | "TIMESTAMP_NTZ";
  value: string;
}

export interface SnowflakeColumn {
  name: string;
  type: string;
  scale?: number;
  precision?: number;
}

export interface SnowflakeResult {
  columns: SnowflakeColumn[];
  rows: Record<string, unknown>[];
  rowCount: number;
  statementHandle: string;
}

// --- in-memory JWT cache (per worker isolate) ---------------------------------
let cachedJwt: SignedJwt | null = null;

async function getJwt(env: SnowflakeEnv): Promise<string> {
  const now = Math.floor(Date.now() / 1000);
  if (cachedJwt && cachedJwt.expiresAt - now > 600) {
    return cachedJwt.token;
  }
  if (!env.SNOWFLAKE_PRIVATE_KEY || !env.SNOWFLAKE_PRIVATE_KEY_FP) {
    throw new Error("set SNOWFLAKE_PAT or SNOWFLAKE_PRIVATE_KEY+_FP secrets");
  }
  cachedJwt = await buildSnowflakeJwt({
    account: env.SNOWFLAKE_ACCOUNT,
    user: env.SNOWFLAKE_USER,
    privateKeyPem: env.SNOWFLAKE_PRIVATE_KEY,
    publicKeyFingerprint: env.SNOWFLAKE_PRIVATE_KEY_FP,
    ttlSeconds: 3540,
  });
  return cachedJwt.token;
}

function authTokenType(env: SnowflakeEnv): string {
  return "KEYPAIR_JWT";
}

function accountHost(account: string): string {
  // Snowflake account locator → https://<account>.snowflakecomputing.com
  // If user supplied a fully qualified hostname, honour it.
  if (account.includes(".snowflakecomputing.com")) return `https://${account}`;
  return `https://${account}.snowflakecomputing.com`;
}

interface RawSnowflakeResponse {
  resultSetMetaData?: {
    numRows?: number;
    rowType?: SnowflakeColumn[];
  };
  data?: unknown[][];
  statementHandle?: string;
  statementStatusUrl?: string;
  code?: string;
  message?: string;
  sqlState?: string;
}

function shapeRows(meta: SnowflakeColumn[] | undefined, data: unknown[][] | undefined): Record<string, unknown>[] {
  if (!meta || !data) return [];
  return data.map((row) => {
    const obj: Record<string, unknown> = {};
    for (let i = 0; i < meta.length; i++) {
      obj[meta[i].name] = row[i];
    }
    return obj;
  });
}

async function pollStatement(env: SnowflakeEnv, jwt: string, handle: string, maxMs = 60_000): Promise<RawSnowflakeResponse> {
  const start = Date.now();
  const url = `${accountHost(env.SNOWFLAKE_ACCOUNT)}/api/v2/statements/${handle}`;
  let delay = 500;
  while (Date.now() - start < maxMs) {
    const r = await fetch(url, {
      headers: {
        Authorization: `Bearer ${jwt}`,
        "X-Snowflake-Authorization-Token-Type": authTokenType(env),
        "User-Agent": "ars-intel-api/0.1",
        Accept: "application/json",
      },
    });
    if (r.status === 200) {
      return (await r.json()) as RawSnowflakeResponse;
    }
    if (r.status !== 202) {
      const body = await r.text();
      throw new Error(`Snowflake poll failed (${r.status}): ${body}`);
    }
    await new Promise((res) => setTimeout(res, delay));
    delay = Math.min(delay * 1.5, 4000);
  }
  throw new Error(`Snowflake statement ${handle} did not complete within ${maxMs}ms`);
}

export async function executeQuery(
  env: SnowflakeEnv,
  sql: string,
  bindings: Record<string, SnowflakeBinding> = {},
): Promise<SnowflakeResult> {
  const jwt = await getJwt(env);
  const url = `${accountHost(env.SNOWFLAKE_ACCOUNT)}/api/v2/statements/`;

  const body = {
    statement: sql,
    warehouse: env.SNOWFLAKE_WAREHOUSE,
    database: env.SNOWFLAKE_DATABASE,
    schema: env.SNOWFLAKE_SCHEMA,
    timeout: 60,
    bindings: Object.keys(bindings).length ? bindings : undefined,
  };

  const r = await fetch(url, {
    method: "POST",
    headers: {
      Authorization: `Bearer ${jwt}`,
      "X-Snowflake-Authorization-Token-Type": authTokenType(env),
      "User-Agent": "ars-intel-api/0.1",
      "Content-Type": "application/json",
      Accept: "application/json",
    },
    body: JSON.stringify(body),
  });

  let payload: RawSnowflakeResponse;
  if (r.status === 200) {
    payload = (await r.json()) as RawSnowflakeResponse;
  } else if (r.status === 202) {
    const handle = (await r.json() as RawSnowflakeResponse).statementHandle;
    if (!handle) throw new Error("Snowflake 202 with no statementHandle");
    payload = await pollStatement(env, jwt, handle);
  } else {
    const txt = await r.text();
    throw new Error(`Snowflake exec failed (${r.status}): ${txt}`);
  }

  if (payload.code && payload.code !== "090001" /* statement executed successfully */) {
    // Snowflake error payload
    if (payload.message) {
      throw new Error(`Snowflake error ${payload.code}: ${payload.message}`);
    }
  }

  const columns = payload.resultSetMetaData?.rowType ?? [];
  const rows = shapeRows(columns, payload.data);
  return {
    columns,
    rows,
    rowCount: payload.resultSetMetaData?.numRows ?? rows.length,
    statementHandle: payload.statementHandle ?? "",
  };
}
