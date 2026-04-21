#!/usr/bin/env bash
# hooks/pre-update.sh
#
# Called by update.sh AFTER secrets reload + image pull + source
# fetch, BEFORE docker compose build. Use for:
#   - Snapshotting the database volume (pg_basebackup, zfs snapshot)
#   - Enabling a maintenance banner on the frontend
#   - Pausing external webhooks (Stripe, OCPI hub) to avoid deliveries
#     during the migration window
#   - Notifying on-call channels that an update window has started
#
# Env vars available:
#   WORKDIR           absolute path to workdir/
#   BRAND_ENV         dev | stage | prod
#   PLATFORM_VERSION  target version (may differ from the currently
#                     installed version, which is in
#                     $WORKDIR/.installed-version)
#
# Exit non-zero to abort the update.

set -euo pipefail

exit 0
