#!/usr/bin/env bash
#
# Rebuild the locally-built images (nginx-certbot, pgbouncer, pgweb, and
# landing where the brand has its own). Platform csms-* images are not
# built here — they come from the registry, see ./install.sh.
#
#   ./docker-build.sh             everything buildable
#   ./docker-build.sh nginx       a single service
#   ./docker-build.sh --no-cache  without layer cache

set -euo pipefail

cd "$(dirname "$0")"

ENV_FILE=workdir/.env
[[ -r "$ENV_FILE" ]] || {
  echo "No $ENV_FILE — stack not installed yet. Run ./install.sh --env=<env>" >&2
  exit 1
}

docker compose --env-file "$ENV_FILE" build "$@"

docker image list
