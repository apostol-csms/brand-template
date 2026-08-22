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

# ─── pgbouncer userlist ──────────────────────────────────────────────
#
# Nothing to do here any more. userlist.txt used to be rebuilt from
# pg_authid, i.e. from the SCRAM verifiers of every application role.
# A verifier authenticates a client but cannot be used to log into the
# server — «server login failed: wrong password type» — which is what
# broke once postgres switched to scram-sha-256 by default.
#
# pgbouncer now authenticates through auth_query and keeps a single
# line of its own: the password of the `pgbouncer` role, written by its
# entrypoint from DB_PASS_PGBOUNCER. The role and the lookup function
# are created by db/sql/pgbouncer.psql on install and by
# hooks/pre-update.sh on an update.

exit 0
