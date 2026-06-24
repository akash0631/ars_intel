"""
ars_replicate.py
================
Mirror arsdbpro/Rep_Data (SQL Server, HOPC345) -> Snowflake V2RETAIL.ARS_BRONZE.

Modes:
    --full          TRUNCATE + INSERT (use for first load or master reseed)
    --incremental   Watermark via V2RETAIL.ARS_GOLD.REPLICATION_WATERMARKS

Watermark column policy (per table):
    Time-stamped fact tables use a datetime column (PARKED_AT, CREATED_AT, etc.)
    Master tables fall back to full reload (table is small).

Env vars required:
    SQL_PASSWORD            SQL Server sa password
    SNOWFLAKE_PASSWORD      Snowflake password for akashv2kart

Usage:
    python ars_replicate.py --full
    python ars_replicate.py --incremental
    python ars_replicate.py --incremental --tables ARS_LISTING_HISTORY,ARS_ALLOC_HISTORY
"""

import argparse
import os
import sys
import logging
from datetime import datetime
from typing import Optional

import pandas as pd
try:
    import pyodbc as _pyodbc
except ImportError:
    _pyodbc = None
try:
    import pymssql as _pymssql
except ImportError:
    _pymssql = None
import snowflake.connector
from snowflake.connector.pandas_tools import write_pandas
from dotenv import load_dotenv

# ---------------------------------------------------------------------------
# Config
# ---------------------------------------------------------------------------
load_dotenv()

SQL_SERVER     = os.environ.get("ARS_SQL_SERVER", "arsdbpro")
SQL_DATABASE   = "Rep_Data"
SQL_USER       = "sa"
SQL_PASSWORD   = os.environ.get("SQL_PASSWORD")

SF_ACCOUNT     = "iafphkw-hh80816"
SF_USER        = "akashv2kart"
SF_PASSWORD    = os.environ.get("SNOWFLAKE_PASSWORD")
SF_WAREHOUSE   = "ALLOC_WH"
SF_DATABASE    = "V2RETAIL"
SF_SCHEMA      = "ARS_BRONZE"
SF_GOLD_SCHEMA = "ARS_GOLD"

# (source_table, target_table, watermark_column or None)
# None watermark_column => incremental falls back to full reload (small master).
TABLES = [
    ("ARS_LISTING_SESSIONS",        "ARS_LISTING_SESSIONS",        "STARTED_AT"),
    ("ARS_LISTING_HISTORY",         "ARS_LISTING_HISTORY",         "PARKED_AT"),
    ("ARS_ALLOC_HISTORY",           "ARS_ALLOC_HISTORY",           None),          # SESSION_ID-based; full per-session reload
    ("ARS_ALLOC_MAJCAT_QUEUE",      "ARS_ALLOC_MAJCAT_QUEUE",      "CREATED_AT"),
    ("ARS_pend_alc",                "ARS_PEND_ALC",                "APPROVED_AT"),
    ("ARS_PEND_ALC_OPERATIONS",     "ARS_PEND_ALC_OPERATIONS",     "OP_DATE"),
    ("ARS_MSA_VAR_ART",             "ARS_MSA_VAR_ART",             "DATE"),
    ("Master_ALC_INPUT_ST_ART",     "MASTER_ALC_INPUT_ST_ART",     "UPLOAD_DATETIME"),
    ("Master_CONT_RNG_SEG",         "MASTER_CONT_RNG_SEG",         None),
    ("Master_CONT_FAB",             "MASTER_CONT_FAB",             None),
    ("Master_CONT_CLR",             "MASTER_CONT_CLR",             None),
    ("Master_CONT_FIT",             "MASTER_CONT_FIT",             None),
    ("Master_CONT_M_VND_CD",        "MASTER_CONT_M_VND_CD",        None),
    ("Master_CONT_M_YARN_02",       "MASTER_CONT_M_YARN_02",       None),
    ("Master_CONT_WEAVE_2",         "MASTER_CONT_WEAVE_2",         None),
    ("Master_CONT_SZ",              "MASTER_CONT_SZ",              None),
    ("Master_CONT_MERGE_RNG_SEG",   "MASTER_CONT_MERGE_RNG_SEG",   None),
    ("STORE_PLANT_MASTER",          "STORE_PLANT_MASTER",          None),
    ("MASTER_PRODUCT",              "MASTER_PRODUCT",              None),
    ("ET_SALES_DATA",               "ET_SALES_DATA",               "DATE"),
]

CHUNK_SIZE = 100_000

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(message)s",
)
log = logging.getLogger("ars_replicate")


# ---------------------------------------------------------------------------
# Connections
# ---------------------------------------------------------------------------
def sql_conn():
    if not SQL_PASSWORD:
        sys.exit("SQL_PASSWORD env var not set")
    backend = os.environ.get("ARS_SQL_BACKEND", "auto")
    if backend in ("auto", "pyodbc") and _pyodbc is not None:
        drivers = [d for d in _pyodbc.drivers() if "SQL Server" in d]
        modern = next((d for d in drivers if "ODBC Driver" in d), None)
        if modern or backend == "pyodbc":
            driver = os.environ.get("ARS_SQL_DRIVER", modern or "ODBC Driver 17 for SQL Server")
            conn_str = (
                f"DRIVER={{{driver}}};"
                f"SERVER={SQL_SERVER};DATABASE={SQL_DATABASE};"
                f"UID={SQL_USER};PWD={SQL_PASSWORD};"
                f"TrustServerCertificate=yes;"
            )
            return _pyodbc.connect(conn_str)
    if _pymssql is None:
        sys.exit("no SQL Server backend: install ODBC Driver 18 (pyodbc) or pip install pymssql")
    return _pymssql.connect(
        server=SQL_SERVER, user=SQL_USER, password=SQL_PASSWORD, database=SQL_DATABASE
    )


def sf_conn() -> snowflake.connector.SnowflakeConnection:
    kwargs = dict(
        account=SF_ACCOUNT,
        user=SF_USER,
        warehouse=SF_WAREHOUSE,
        database=SF_DATABASE,
        schema=SF_SCHEMA,
    )
    key_path = os.environ.get("SNOWFLAKE_PRIVATE_KEY_PATH",
                              os.path.expanduser("~/.snowflake/akashv2kart_rsa.p8"))
    if os.path.exists(key_path):
        from cryptography.hazmat.primitives import serialization
        with open(key_path, "rb") as kf:
            p_key = serialization.load_pem_private_key(kf.read(), password=None)
        kwargs["private_key"] = p_key.private_bytes(
            encoding=serialization.Encoding.DER,
            format=serialization.PrivateFormat.PKCS8,
            encryption_algorithm=serialization.NoEncryption(),
        )
    elif SF_PASSWORD:
        kwargs["password"] = SF_PASSWORD
    else:
        sys.exit("need ~/.snowflake/akashv2kart_rsa.p8 or SNOWFLAKE_PASSWORD env")
    return snowflake.connector.connect(**kwargs)


# ---------------------------------------------------------------------------
# Watermark helpers
# ---------------------------------------------------------------------------
def get_watermark(sf, table_name: str) -> Optional[datetime]:
    cur = sf.cursor()
    cur.execute(
        f"SELECT LAST_LOADED_AT FROM {SF_DATABASE}.{SF_GOLD_SCHEMA}.REPLICATION_WATERMARKS "
        f"WHERE TABLE_NAME = %s",
        (table_name,),
    )
    row = cur.fetchone()
    cur.close()
    return row[0] if row else None


def set_watermark(sf, table_name: str, last_loaded_at: datetime, rows_loaded: int) -> None:
    cur = sf.cursor()
    cur.execute(
        f"""
        MERGE INTO {SF_DATABASE}.{SF_GOLD_SCHEMA}.REPLICATION_WATERMARKS t
        USING (SELECT %s AS TABLE_NAME, %s AS LAST_LOADED_AT, %s AS ROWS_LOADED) s
        ON t.TABLE_NAME = s.TABLE_NAME
        WHEN MATCHED THEN UPDATE SET
            LAST_LOADED_AT = s.LAST_LOADED_AT,
            ROWS_LOADED    = s.ROWS_LOADED
        WHEN NOT MATCHED THEN INSERT (TABLE_NAME, LAST_LOADED_AT, ROWS_LOADED)
            VALUES (s.TABLE_NAME, s.LAST_LOADED_AT, s.ROWS_LOADED)
        """,
        (table_name, last_loaded_at, rows_loaded),
    )
    sf.commit()
    cur.close()


# ---------------------------------------------------------------------------
# Replication
# ---------------------------------------------------------------------------
def truncate_target(sf, target_table: str) -> None:
    cur = sf.cursor()
    cur.execute(f"DROP TABLE IF EXISTS {SF_DATABASE}.{SF_SCHEMA}.{target_table}")
    sf.commit()
    cur.close()


def stream_to_snowflake(sql, sf, query: str, target_table: str) -> int:
    """Stream-read SQL Server in chunks, write each chunk to Snowflake."""
    total = 0
    chunk_iter = pd.read_sql(query, sql, chunksize=CHUNK_SIZE)
    for i, df in enumerate(chunk_iter, start=1):
        if df.empty:
            continue
        def _norm(c: str) -> str:
            import re as _re
            s = _re.sub(r"[^A-Za-z0-9_]", "_", c).upper()
            if s and s[0].isdigit():
                s = "_" + s
            return s
        df.columns = [_norm(c) for c in df.columns]
        success, nchunks, nrows, _ = write_pandas(
            sf, df, target_table,
            database=SF_DATABASE, schema=SF_SCHEMA,
            quote_identifiers=False,
            auto_create_table=(i == 1),
            overwrite=False,
        )
        if not success:
            raise RuntimeError(f"write_pandas failed for {target_table} chunk {i}")
        total += nrows
        log.info(f"  {target_table}: chunk {i} -> {nrows:,} rows (running total {total:,})")
    return total


def replicate_table(sql, sf, source: str, target: str, wm_col: Optional[str], mode: str) -> None:
    log.info(f"==> {source} -> {target} [mode={mode}, wm_col={wm_col}]")

    if mode == "full" or wm_col is None:
        log.info(f"  TRUNCATE {target}")
        truncate_target(sf, target)
        query = f"SELECT * FROM dbo.{source}"
        new_high_water = datetime.utcnow()
    else:
        last = get_watermark(sf, target)
        if last is None:
            log.info(f"  no watermark -> full load")
            truncate_target(sf, target)
            query = f"SELECT * FROM dbo.{source}"
        else:
            log.info(f"  incremental from {last.isoformat()}")
            query = (
                f"SELECT * FROM dbo.{source} "
                f"WHERE [{wm_col}] > '{last.strftime('%Y-%m-%d %H:%M:%S')}'"
            )
        new_high_water = datetime.utcnow()

    rows = stream_to_snowflake(sql, sf, query, target)
    set_watermark(sf, target, new_high_water, rows)
    log.info(f"  done: {rows:,} rows")


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--full", action="store_true", help="TRUNCATE + INSERT all tables")
    ap.add_argument("--incremental", action="store_true", help="Use watermarks")
    ap.add_argument("--tables", help="Comma-separated subset of target table names")
    args = ap.parse_args()

    if not (args.full or args.incremental):
        ap.error("specify --full or --incremental")

    mode = "full" if args.full else "incremental"
    only = set(args.tables.split(",")) if args.tables else None

    log.info(f"ars_replicate starting [mode={mode}]")

    sql = sql_conn()
    sf  = sf_conn()
    try:
        for src, tgt, wm in TABLES:
            if only and tgt not in only:
                continue
            try:
                replicate_table(sql, sf, src, tgt, wm, mode)
            except Exception as e:
                log.error(f"  FAILED {tgt}: {e}")
    finally:
        sql.close()
        sf.close()

    log.info("ars_replicate complete")


if __name__ == "__main__":
    main()
