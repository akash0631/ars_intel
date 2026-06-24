"""Execute a SQL file (or list of files) against Snowflake via snowflake-connector.

Splits on ';' at top-level (skips inside string literals, $$ blocks).
"""

import os
import sys
import re
import snowflake.connector


def split_statements(sql_text: str):
    """Naive SQL splitter — handles single-quoted strings and $$...$$ blocks."""
    stmts = []
    buf = []
    in_sq = False
    in_dollar = False
    i = 0
    while i < len(sql_text):
        ch = sql_text[i]
        nxt = sql_text[i + 1] if i + 1 < len(sql_text) else ""
        if not in_dollar and ch == "'" and not in_sq:
            in_sq = True
            buf.append(ch)
        elif in_sq and ch == "'":
            if nxt == "'":
                buf.append("''")
                i += 2
                continue
            in_sq = False
            buf.append(ch)
        elif not in_sq and ch == "$" and nxt == "$":
            in_dollar = not in_dollar
            buf.append("$$")
            i += 2
            continue
        elif ch == "-" and nxt == "-" and not in_sq and not in_dollar:
            # comment to EOL
            while i < len(sql_text) and sql_text[i] != "\n":
                buf.append(sql_text[i])
                i += 1
            continue
        elif ch == ";" and not in_sq and not in_dollar:
            s = "".join(buf).strip()
            if s:
                stmts.append(s)
            buf = []
        else:
            buf.append(ch)
        i += 1
    tail = "".join(buf).strip()
    if tail:
        stmts.append(tail)
    return stmts


def main():
    if len(sys.argv) < 2:
        print("usage: run_sql.py <file.sql> [<file.sql> ...]", file=sys.stderr)
        sys.exit(2)

    kwargs = dict(
        account=os.environ.get("SNOWFLAKE_ACCOUNT", "iafphkw-hh80816"),
        user=os.environ.get("SNOWFLAKE_USER", "akashv2kart"),
        warehouse=os.environ.get("SNOWFLAKE_WAREHOUSE", "ALLOC_WH"),
        database=os.environ.get("SNOWFLAKE_DATABASE", "V2RETAIL"),
    )
    key_path = os.environ.get("SNOWFLAKE_PRIVATE_KEY_PATH",
                              os.path.expanduser("~/.snowflake/akashv2kart_rsa.p8"))
    pwd = os.environ.get("SNOWFLAKE_PASSWORD")
    if os.path.exists(key_path):
        from cryptography.hazmat.primitives import serialization
        with open(key_path, "rb") as kf:
            p_key = serialization.load_pem_private_key(kf.read(), password=None)
        kwargs["private_key"] = p_key.private_bytes(
            encoding=serialization.Encoding.DER,
            format=serialization.PrivateFormat.PKCS8,
            encryption_algorithm=serialization.NoEncryption(),
        )
    elif pwd:
        kwargs["password"] = pwd
    else:
        print("need ~/.snowflake/akashv2kart_rsa.p8 or SNOWFLAKE_PASSWORD env", file=sys.stderr)
        sys.exit(2)
    conn = snowflake.connector.connect(**kwargs)
    cur = conn.cursor()
    try:
        for fp in sys.argv[1:]:
            print(f"\n=== {fp} ===", flush=True)
            with open(fp, "r", encoding="utf-8") as fh:
                sql_text = fh.read()
            stmts = split_statements(sql_text)
            print(f"  {len(stmts)} statements", flush=True)
            for idx, stmt in enumerate(stmts, 1):
                preview = re.sub(r"\s+", " ", stmt)[:90]
                try:
                    cur.execute(stmt)
                    rc = cur.rowcount if cur.rowcount is not None else "-"
                    print(f"  [{idx:>3}/{len(stmts)}] ok  ({rc} rows) :: {preview}", flush=True)
                except Exception as e:
                    print(f"  [{idx:>3}/{len(stmts)}] FAIL :: {preview}", flush=True)
                    print(f"        err: {e}", flush=True)
                    raise
    finally:
        cur.close()
        conn.close()
    print("\nDONE")


if __name__ == "__main__":
    main()
