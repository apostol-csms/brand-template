#!/bin/bash
#
# CRM schema migration — runs on every deploy.
# Calls migrate.sh (same logic as install.sh --migrate).
#
# Expects:
#   /crm-db/  — mounted from backend/db/ (read-only)
#   PGHOST, PGPORT, PGUSER, PGPASSWORD — env vars
#
# Runtime deps (bash, grep -P, find, psql) come from the image built by
# .docker/db-migrate/Dockerfile (debian-slim + postgresql-client-18).
#

set -e

START_TS=$SECONDS

PGHOST="${PGHOST:-postgres}"
PGPORT="${PGPORT:-5432}"
PGUSER="${PGUSER:-postgres}"
PG_PASS="${PGPASSWORD:-${POSTGRES_PASSWORD:-postgres}}"

# PGDATABASE env > first arg > default `csms`.
DB_NAME="${PGDATABASE:-${1:-csms}}"
export PGDATABASE="$DB_NAME"

# Extract DB user passwords from .env.psql (lives at sql/ root after the
# flat-layout refactor; brand/apply.sh places it there on the host).
ENV_FILE="/crm-db/sql/.env.psql"
extract_pass() { grep -oP "\\\\set $1 '\\K[^']+" "$ENV_FILE" 2>/dev/null || echo "$2"; }

# .pgpass for all db-platform users (patches use \connect :dbname kernel/admin)
PGPASSFILE="/root/.pgpass"
cat > "$PGPASSFILE" <<EOF
$PGHOST:$PGPORT:*:$PGUSER:$PG_PASS
$PGHOST:$PGPORT:*:kernel:$(extract_pass kernel)
$PGHOST:$PGPORT:*:admin:$(extract_pass admin)
$PGHOST:$PGPORT:*:daemon:$(extract_pass daemon)
$PGHOST:$PGPORT:*:apibot:$(extract_pass apibot)
EOF
chmod 600 "$PGPASSFILE"
export PGPASSFILE

# Unset PGPASSWORD so psql uses .pgpass (PGPASSWORD overrides .pgpass)
unset PGPASSWORD

export PGHOST PGPORT
PSQL_PG="psql -h $PGHOST -p $PGPORT -U $PGUSER"
export PSQL_KERNEL="psql -h $PGHOST -p $PGPORT -U kernel"

echo
echo "============================================"
echo " CRM schema migration — $(date -Iseconds)"
echo " Database: $DB_NAME"
echo "============================================"
echo

# Check if database exists
if ! $PSQL_PG -lqt | cut -d \| -f 1 | grep -qw "$DB_NAME"; then
  echo "Database '$DB_NAME' does not exist yet — skipping."
  exit 0
fi

# Check if db-platform is installed
HAS_KERNEL=$($PSQL_PG -d "$DB_NAME" -tAc \
  "SELECT 1 FROM information_schema.schemata WHERE schema_name = 'kernel'" 2>/dev/null || true)

if [[ "$HAS_KERNEL" != "1" ]]; then
  echo "Schema 'kernel' not found — skipping."
  exit 0
fi

# Copy to writable location (migrate.sh writes temp files in sql/)
WORK="/tmp/crm-db"
cp -a /crm-db "$WORK"
chmod +x "$WORK/migrate.sh"

cd "$WORK"

# First run: baseline if patch_log doesn't exist yet
HAS_PATCH_LOG=$($PSQL_PG -d "$DB_NAME" -tAc \
  "SELECT 1 FROM information_schema.tables WHERE table_schema = 'db' AND table_name = 'patch_log'" 2>/dev/null || true)

if [[ "$HAS_PATCH_LOG" != "1" ]]; then
  echo ">>> First run — baselining existing patches..."
  BASELINE_TS=$SECONDS
  bash migrate.sh --baseline
  echo ">>> Baseline took $((SECONDS - BASELINE_TS))s."
  echo
fi

# Apply new patches + always update routines/views
echo ">>> Applying patches + updating routines/views..."
UPDATE_TS=$SECONDS
bash migrate.sh --force-update
echo ">>> Patches + update took $((SECONDS - UPDATE_TS))s."

echo
echo "============================================"
echo " CRM schema migration complete (total $((SECONDS - START_TS))s)"
echo "============================================"
echo
