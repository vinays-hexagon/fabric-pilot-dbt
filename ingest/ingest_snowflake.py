"""
Ingests MDO tables from Snowflake (as_analytics) into the raw schema of
the Fabric Warehouse (dbt-pilot-wh).

Auth:
  - Snowflake : username/password via env vars
  - Fabric    : DefaultAzureCredential (Azure CLI locally, Service Principal in CI)

Usage:
  python ingest/ingest_snowflake.py [--tables stg_ref_organization stg_customer_master ...]
"""
import argparse
import logging
import os
import struct
import sys

import pyodbc
import snowflake.connector
from azure.identity import DefaultAzureCredential

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s  %(levelname)-7s  %(message)s",
    datefmt="%H:%M:%S",
)
log = logging.getLogger(__name__)

# ── Config ────────────────────────────────────────────────────────────────────

SNOWFLAKE_CFG = {
    "account":   os.environ["SNOWFLAKE_ACCOUNT"],
    "user":      os.environ["SNOWFLAKE_USER"],
    "password":  os.environ["SNOWFLAKE_PASSWORD"],
    "role":      os.environ.get("SNOWFLAKE_ROLE", "transformer"),
    "warehouse": os.environ.get("SNOWFLAKE_WAREHOUSE", "transforming"),
    "database":  os.environ.get("SNOWFLAKE_DATABASE", "as_analytics"),
    "schema":    os.environ.get("SNOWFLAKE_SCHEMA", "dbt_vsesham_mdo"),
}

FABRIC_SERVER   = os.environ["DBT_FABRIC_SERVER"]
FABRIC_DATABASE = os.environ["DBT_FABRIC_DATABASE"]
FABRIC_SCHEMA   = os.environ.get("INGEST_TARGET_SCHEMA", "raw")
ODBC_DRIVER     = os.environ.get("ODBC_DRIVER", "ODBC Driver 17 for SQL Server")

DEFAULT_TABLES = [
    "stg_ref_organization",
    "stg_ref_location",
    "stg_customer_master",
    "stg_product_master",
    "stg_chart_of_accounts",
]

# ── Fabric connection via Azure AD token ──────────────────────────────────────

def fabric_connect() -> pyodbc.Connection:
    credential = DefaultAzureCredential()
    token = credential.get_token("https://database.windows.net/.default").token
    token_bytes = token.encode("utf-16-le")
    token_struct = struct.pack(f"<I{len(token_bytes)}s", len(token_bytes), token_bytes)

    conn_str = (
        f"DRIVER={{{ODBC_DRIVER}}};"
        f"SERVER={FABRIC_SERVER};"
        f"DATABASE={FABRIC_DATABASE};"
        "Encrypt=yes;TrustServerCertificate=no;"
    )
    return pyodbc.connect(conn_str, attrs_before={1256: token_struct})


# ── Helpers ───────────────────────────────────────────────────────────────────

def snowflake_type_to_tsql(sf_type: str) -> str:
    """Map Snowflake column type to a safe T-SQL type for the raw layer."""
    sf = sf_type.upper()
    if any(t in sf for t in ("NUMBER", "FLOAT", "DECIMAL", "NUMERIC")):
        return "FLOAT"
    if any(t in sf for t in ("TIMESTAMP", "DATETIME")):
        return "DATETIME2"
    if "DATE" in sf:
        return "DATE"
    if "BOOLEAN" in sf:
        return "BIT"
    return "VARCHAR(4000)"   # Fabric Warehouse (trial) does not support NVARCHAR


def ensure_schema(fab_cur: pyodbc.Cursor, schema: str) -> None:
    fab_cur.execute(
        f"IF NOT EXISTS (SELECT 1 FROM sys.schemas WHERE name = '{schema}') "
        f"EXEC('CREATE SCHEMA [{schema}]')"
    )


def ingest_table(sf_conn, fab_conn, table: str) -> int:
    sf_cur  = sf_conn.cursor()
    fab_cur = fab_conn.cursor()

    log.info("%-40s  fetching from Snowflake ...", table)
    sf_cur.execute(f"SELECT * FROM {table}")
    rows    = sf_cur.fetchall()
    columns = [d[0].lower() for d in sf_cur.description]
    sf_types = [d[1].__name__ if hasattr(d[1], '__name__') else str(d[1])
                for d in sf_cur.description]

    col_defs = ", ".join(
        f"[{col}] {snowflake_type_to_tsql(sf_types[i])}"
        for i, col in enumerate(columns)
    )

    # Recreate target table (full refresh)
    fab_cur.execute(
        f"IF OBJECT_ID('[{FABRIC_SCHEMA}].[{table}]', 'U') IS NOT NULL "
        f"DROP TABLE [{FABRIC_SCHEMA}].[{table}]"
    )
    fab_cur.execute(f"CREATE TABLE [{FABRIC_SCHEMA}].[{table}] ({col_defs})")

    if rows:
        placeholders = ", ".join("?" * len(columns))
        fab_cur.fast_executemany = True
        fab_cur.executemany(
            f"INSERT INTO [{FABRIC_SCHEMA}].[{table}] VALUES ({placeholders})",
            [list(r) for r in rows],
        )

    fab_conn.commit()
    log.info("%-40s  loaded %d rows -> [%s].[%s]", table, len(rows), FABRIC_SCHEMA, table)
    return len(rows)


# ── Main ──────────────────────────────────────────────────────────────────────

def main() -> None:
    parser = argparse.ArgumentParser(description="Snowflake → Fabric Warehouse ingestion")
    parser.add_argument("--tables", nargs="+", default=DEFAULT_TABLES,
                        help="Tables to ingest (default: all MDO tables)")
    args = parser.parse_args()

    log.info("Connecting to Snowflake (%s / %s.%s) ...",
             SNOWFLAKE_CFG["account"], SNOWFLAKE_CFG["database"], SNOWFLAKE_CFG["schema"])
    sf_conn = snowflake.connector.connect(**SNOWFLAKE_CFG)

    log.info("Connecting to Fabric Warehouse (%s) ...", FABRIC_SERVER)
    fab_conn = fabric_connect()

    ensure_schema(fab_conn.cursor(), FABRIC_SCHEMA)
    fab_conn.commit()

    total_rows = 0
    failed     = []

    for table in args.tables:
        try:
            total_rows += ingest_table(sf_conn, fab_conn, table)
        except Exception as exc:
            log.error("%-40s  FAILED: %s", table, exc)
            failed.append(table)

    sf_conn.close()
    fab_conn.close()

    log.info("Done. %d tables ingested, %d rows total.", len(args.tables) - len(failed), total_rows)

    if failed:
        log.error("Failed tables: %s", failed)
        sys.exit(1)


if __name__ == "__main__":
    main()
