#!/usr/bin/env bash
#
# Stack logs.
#
#   ./docker-logs.sh                     everything, last 500 lines, follow
#   ./docker-logs.sh backend             a single service
#   ./docker-logs.sh db-init db-migrate  database install and migrations

set -euo pipefail

cd "$(dirname "$0")"

ENV_FILE=workdir/.env
[[ -r "$ENV_FILE" ]] || { echo "No $ENV_FILE — stack not installed yet" >&2; exit 1; }

docker compose --env-file "$ENV_FILE" logs -fn 500 "$@"
