#!/usr/bin/env bash
# run_pipeline.sh — End-to-end pipeline: Snowflake → Fabric → dbt → Elementary
# Usage: ./run_pipeline.sh [--skip-ingest] [--skip-dbt] [--skip-elementary]

set -euo pipefail

DBT="$HOME/.dbt/fabric-venv/bin/dbt"
EDR="$HOME/.dbt/fabric-venv/bin/edr"
PYTHON="$HOME/.dbt/fabric-venv/bin/python"
PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROFILES_DIR="$HOME/.dbt"

SKIP_INGEST=false
SKIP_DBT=false
SKIP_ELEMENTARY=false

for arg in "$@"; do
  case $arg in
    --skip-ingest)     SKIP_INGEST=true ;;
    --skip-dbt)        SKIP_DBT=true ;;
    --skip-elementary) SKIP_ELEMENTARY=true ;;
  esac
done

log() { echo "[$(date '+%H:%M:%S')] $*"; }
fail() { echo "[$(date '+%H:%M:%S')] ERROR: $*" >&2; exit 1; }

cd "$PROJECT_DIR"

# ── Step 1: Ingest from Snowflake ─────────────────────────────────────────────
if [ "$SKIP_INGEST" = false ]; then
  log "Step 1/3 — Ingesting MDO tables from Snowflake into Fabric raw schema ..."

  : "${SNOWFLAKE_ACCOUNT:?SNOWFLAKE_ACCOUNT env var required}"
  : "${SNOWFLAKE_USER:?SNOWFLAKE_USER env var required}"
  : "${SNOWFLAKE_PASSWORD:?SNOWFLAKE_PASSWORD env var required}"
  : "${DBT_FABRIC_SERVER:?DBT_FABRIC_SERVER env var required}"
  : "${DBT_FABRIC_DATABASE:?DBT_FABRIC_DATABASE env var required}"

  ODBC_DRIVER="${ODBC_DRIVER:-ODBC Driver 17 for SQL Server}" \
    "$PYTHON" ingest/ingest_snowflake.py
  log "Ingest complete."
else
  log "Step 1/3 — Skipping ingest (--skip-ingest)."
fi

# ── Step 2: dbt build ─────────────────────────────────────────────────────────
if [ "$SKIP_DBT" = false ]; then
  log "Step 2/3 — Running dbt build (seed + run + test) ..."
  "$DBT" deps   --profiles-dir "$PROFILES_DIR" --profile fabric_pilot
  "$DBT" seed   --profiles-dir "$PROFILES_DIR" --profile fabric_pilot
  "$DBT" run    --profiles-dir "$PROFILES_DIR" --profile fabric_pilot
  "$DBT" test   --profiles-dir "$PROFILES_DIR" --profile fabric_pilot
  log "dbt build complete."
else
  log "Step 2/3 — Skipping dbt build (--skip-dbt)."
fi

# ── Step 3: Elementary report ─────────────────────────────────────────────────
if [ "$SKIP_ELEMENTARY" = false ]; then
  log "Step 3/3 — Generating Elementary data quality report ..."
  "$EDR" report --profiles-dir "$PROFILES_DIR" --profile-target dev
  log "Elementary report saved to: $PROJECT_DIR/edr_target/elementary_report.html"
  open "$PROJECT_DIR/edr_target/elementary_report.html" 2>/dev/null || true
else
  log "Step 3/3 — Skipping Elementary report (--skip-elementary)."
fi

log "Pipeline complete."
