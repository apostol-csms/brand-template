#!/usr/bin/env bash
# hooks/post-install.sh
#
# Called by install.sh AFTER `docker compose up -d` but BEFORE the
# final check.sh verification. Default behaviour: regenerate the
# pgbouncer userlist.txt from postgres pg_authid (Phase-4-aware csms-db
# image generates random or operator-supplied SCRAM-SHA-256 passwords
# at first install — they need to land in pgbouncer for connection
# pooling to work).
#
# Brands extend with additional post-deploy actions:
#   - Smoke-testing a specific brand workflow
#   - Attaching monitors / log forwarders to running containers
#   - Sending "deployment finished" notifications
#   - Running brand-specific data imports (kladr, partner catalogs)
#
# Env vars available:
#   WORKDIR           absolute path to workdir/
#   BRAND_ENV         dev | stage | prod
#   PLATFORM_VERSION  pinned semver
#
# Per-env override: envs/<env>/hooks/post-install.sh runs in addition.
#
# Exit non-zero to abort (check.sh still runs afterwards in install.sh,
# so a failing post-install hook may or may not surface as a failed
# install depending on the check).

set -euo pipefail

: "${WORKDIR:?WORKDIR required}"

SCRIPT_DIR="$(dirname "$WORKDIR")"      # brand-repo root

# ─── Regenerate pgbouncer userlist.txt from pg_authid ───────────────
#
# The csms-db image's entrypoint-secrets.sh (Phase 4) writes random
# (or operator-supplied via DB_PASS_*) SCRAM-SHA-256 passwords into
# postgres role definitions during db-init.  pgbouncer needs an
# exact-match userlist.txt to authenticate runtime connections.
#
# Strategy:
#   1. Query pg_authid for the SCRAM-SHA-256 hash strings of the 5
#      runtime-app roles (kernel/admin/daemon/apibot/ocpp).  Returned
#      as already-formatted pgbouncer lines.
#   2. Write to workdir/pgbouncer/userlist.txt — the path bind-mounted
#      RO into the pgbouncer container at /etc/pgbouncer/userlist.txt
#      (overrides the placeholder baked into the image at build time).
#   3. Restart pgbouncer to re-read the file.
#
# Idempotent: re-running the hook just re-queries pg_authid and
# rewrites the file (passwords don't change unless csms-secrets volume
# is destroyed + reinitialised).

USERLIST="$WORKDIR/pgbouncer/userlist.txt"
mkdir -p "$(dirname "$USERLIST")"

# `set -a; source $WORKDIR/.env; set +a` would be the natural way to
# load brand env, but install.sh's preflight already loaded everything
# we need into `compose --env-file`.  Use compose exec so the query
# uses the right network + .pgpass.
COMPOSE="docker compose --env-file $WORKDIR/.env"

echo "hook/post-install: regenerating pgbouncer userlist from pg_authid"

# `\copy` would be cleaner but pg_authid is restricted; query as
# postgres superuser via `compose exec`.  Format inline to avoid
# shelling-out a python step.
$COMPOSE exec -T postgres \
    psql -U postgres -tA \
         -c "SELECT '\"' || rolname || '\" \"' || rolpassword || '\"'
             FROM pg_authid
             WHERE rolname IN ('kernel','admin','daemon','apibot','ocpp','ocpi','http','mailbot')
             ORDER BY rolname" \
    > "$USERLIST"

if [[ ! -s "$USERLIST" ]]; then
    echo "hook/post-install: WARN: pg_authid query returned empty — pgbouncer auth will fail" >&2
    exit 1
fi

chmod 600 "$USERLIST"
echo "hook/post-install: userlist written ($(wc -l < "$USERLIST") roles)"

# Restart pgbouncer so it picks up the new file.  No-op if pgbouncer
# isn't in the compose stack (compose ignores unknown services with
# a warning, which is fine for non-pooled brands).
$COMPOSE restart pgbouncer 2>&1 | sed 's/^/hook\/post-install: /'
