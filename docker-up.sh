#!/usr/bin/env bash
#
# Bring the brand stack up.
#
#   ./docker-up.sh                    start (images used as-is)
#   ./docker-up.sh --build            rebuild local images, then start
#   ./docker-up.sh backend ocpp       start only the named services
#   ./docker-up.sh --force-recreate   recreate containers
#
# Start order and readiness gating live in docker-compose.yaml via
# depends_on/condition — db-init and db-migrate sort themselves out.
#
# First-time deployment goes through ./install.sh --env=<env>, not this
# script: it merges .env, pulls secrets and renders app-env. This one is
# plain `docker compose up` for a stack that is already installed.

set -euo pipefail

cd "$(dirname "$0")"

ENV_FILE=workdir/.env
[[ -r "$ENV_FILE" ]] || {
  echo "No $ENV_FILE — stack not installed yet. Run ./install.sh --env=<env>" >&2
  exit 1
}

docker compose --env-file "$ENV_FILE" up -d "$@"

echo
docker compose --env-file "$ENV_FILE" ps
echo

# DOMAIN is read with sed, not `source`: the file carries values with a
# semicolon in them (inline data: URIs for brand artwork), and bash would
# split such a line into two commands.
DOMAIN="$(sed -n 's/^DOMAIN=//p' "$ENV_FILE" | tail -1 | tr -d '"')"
if [[ -n "$DOMAIN" ]]; then
  echo "  https://cloud.$DOMAIN     tenant dashboard"
  echo "  https://cpo.$DOMAIN       operator dashboard"
  echo "  https://admin.$DOMAIN     platform admin"
  echo "  https://driver.$DOMAIN    driver PWA"
  echo "  https://pay.$DOMAIN       QR ad-hoc payment"
  echo "  https://api.$DOMAIN       REST API"
  echo "  https://ocpp.$DOMAIN      OCPP Central System"
  echo
fi
echo "Logs: ./docker-logs.sh   Health: ./check.sh"
