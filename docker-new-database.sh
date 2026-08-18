#!/usr/bin/env bash
#
# ⚠ DESTRUCTIVE. Recreate the database from scratch: stop the stack, drop
# the PostgreSQL volume and bring it back up — db-init lays down schema
# and seed, db-migrate catches up on patches.
#
#   ./docker-new-database.sh          ask for confirmation
#   ./docker-new-database.sh --yes    skip the prompt (for scripts)
#
# The letsencrypt, files and csms-secrets volumes are left alone: TLS
# survives a database rebuild, and csms-secrets holds the role passwords —
# drop it and you get a database with fresh passwords and a stale
# workdir/.env.

set -euo pipefail

cd "$(dirname "$0")"

ENV_FILE=workdir/.env
[[ -r "$ENV_FILE" ]] || {
  echo "No $ENV_FILE — stack not installed yet. Run ./install.sh --env=<env>" >&2
  exit 1
}

# sed, not `source`: the file carries values with a semicolon in them
# (inline data: URIs for brand artwork) and bash would run them.
PROJECT_NAME="$(sed -n 's/^PROJECT_NAME=//p' "$ENV_FILE" | tail -1 | tr -d '"')"
[[ -n "$PROJECT_NAME" ]] || { echo "PROJECT_NAME is not set in $ENV_FILE" >&2; exit 1; }
VOLUME="${PROJECT_NAME}_postgresql"

if ! docker volume inspect "$VOLUME" >/dev/null 2>&1; then
  echo "Volume '$VOLUME' does not exist — the database is empty already. ./docker-up.sh is enough"
  exit 0
fi

if [[ "${1:-}" != "--yes" ]]; then
  echo
  echo "Volume '$VOLUME' will be removed — ALL DATABASE DATA WILL BE LOST."
  echo "Project: $PROJECT_NAME"
  read -r -p "Recreate the database? (y/N): " ans
  if [[ "$ans" != "y" && "$ans" != "Y" ]]; then
    echo "Cancelled."
    exit 0
  fi
fi

./docker-down.sh

docker volume rm -f "$VOLUME"

docker compose --env-file "$ENV_FILE" up -d
docker compose --env-file "$ENV_FILE" logs -f --tail 200 db-init db-migrate
