// JWT builder for Snowflake key-pair auth.
// Snowflake expects RS256 with claims:
//   iss = "<ACCOUNT_UPPER>.<USER_UPPER>.SHA256:<fp>"
//   sub = "<ACCOUNT_UPPER>.<USER_UPPER>"
//   iat = now
//   exp = now + ~59 min (Snowflake caps at 60)

function b64url(bytes: ArrayBuffer | Uint8Array): string {
  const u8 = bytes instanceof Uint8Array ? bytes : new Uint8Array(bytes);
  let bin = "";
  for (let i = 0; i < u8.length; i++) bin += String.fromCharCode(u8[i]);
  return btoa(bin).replace(/=+$/, "").replace(/\+/g, "-").replace(/\//g, "_");
}

function b64urlJson(obj: unknown): string {
  return b64url(new TextEncoder().encode(JSON.stringify(obj)));
}

// PEM -> raw DER bytes
function pemToDer(pem: string): ArrayBuffer {
  const body = pem
    .replace(/-----BEGIN [^-]+-----/g, "")
    .replace(/-----END [^-]+-----/g, "")
    .replace(/\s+/g, "");
  const bin = atob(body);
  const buf = new Uint8Array(bin.length);
  for (let i = 0; i < bin.length; i++) buf[i] = bin.charCodeAt(i);
  return buf.buffer;
}

async function importRsaPrivateKey(pem: string): Promise<CryptoKey> {
  const der = pemToDer(pem);
  return crypto.subtle.importKey(
    "pkcs8",
    der,
    { name: "RSASSA-PKCS1-v1_5", hash: "SHA-256" },
    false,
    ["sign"],
  );
}

export interface BuildJwtArgs {
  account: string;          // e.g. "iafphkw-hh80816"  (account locator, no region)
  user: string;             // e.g. "akashv2kart"
  privateKeyPem: string;    // PKCS#8 PEM
  publicKeyFingerprint: string; // "SHA256:..." from DESC USER
  ttlSeconds?: number;      // default 3540 (59 min)
}

export interface SignedJwt {
  token: string;
  expiresAt: number; // epoch seconds
}

export async function buildSnowflakeJwt(args: BuildJwtArgs): Promise<SignedJwt> {
  const ttl = args.ttlSeconds ?? 3540;
  const now = Math.floor(Date.now() / 1000);
  const exp = now + ttl;

  const account = args.account.toUpperCase().split(".")[0]; // strip region if present
  const user = args.user.toUpperCase();
  const fp = args.publicKeyFingerprint.startsWith("SHA256:")
    ? args.publicKeyFingerprint
    : `SHA256:${args.publicKeyFingerprint}`;

  const header = { alg: "RS256", typ: "JWT" };
  const payload = {
    iss: `${account}.${user}.${fp}`,
    sub: `${account}.${user}`,
    iat: now,
    exp,
  };

  const signingInput = `${b64urlJson(header)}.${b64urlJson(payload)}`;
  const key = await importRsaPrivateKey(args.privateKeyPem);
  const sig = await crypto.subtle.sign(
    "RSASSA-PKCS1-v1_5",
    key,
    new TextEncoder().encode(signingInput),
  );

  return {
    token: `${signingInput}.${b64url(sig)}`,
    expiresAt: exp,
  };
}
