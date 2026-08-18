#!/usr/bin/env bash
#
# Stop the stack. Database data survives in the <PROJECT_NAME>_postgresql
# volume.
#
#   ./docker-down.sh              stop everything
#   ./docker-down.sh backend      stop a single service
#   ./docker-down.sh --volumes    ⚠ drop the volumes too (data is lost)

set -euo pipefail

cd "$(dirname "$0")"

ENV_FILE=workdir/.env
[[ -r "$ENV_FILE" ]] || { echo "No $ENV_FILE — nothing to stop" >&2; exit 1; }

docker compose --env-file "$ENV_FILE" down "$@"
