#!/usr/bin/env bash
# hooks/pre-update.sh
#
# Called by update.sh AFTER secrets reload + image pull + source
# fetch, BEFORE docker compose build. Default behaviour: stage a
# possibly-rotated license.json from .secrets/ into conf/ so the
# backend's LicenseServer re-reads it on the next HUP / restart.
# Brands extend with additional update-window setup:
#   - Snapshotting the database volume (pg_basebackup, zfs snapshot)
#   - Enabling a maintenance banner on the frontend
#   - Pausing external webhooks (Stripe, OCPI hub) to avoid deliveries
#     during the migration window
#   - Notifying on-call channels that an update window has started
#
# Note on SSL: the nginx-certbot container's internal renewal cycle
# (`certbot renew && nginx -s reload`) writes into the runtime
# `letsencrypt:` named volume, NOT back to host's .secrets/.  This
# hook therefore does NOT re-stage TLS — the build-context copy is
# only consulted on first install / image rebuild.
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

: "${WORKDIR:?WORKDIR required}"

SCRIPT_DIR="$(dirname "$WORKDIR")"      # brand-repo root
PARENT="$(dirname "$SCRIPT_DIR")"       # sibling of .secrets/

# Stage rotated license.json (license-aware brands).  Operator drops a
# renewed envelope into .secrets/license.json (typically via CI/CD's
# LICENSE_JSON Secret refresh); this hook propagates it into the
# compose mount path.  No-op when license.json absent (legacy brands).
if [[ -f "$PARENT/.secrets/license.json" ]]; then
  CONF_DIR="$SCRIPT_DIR/conf"
  echo "hook/pre-update: re-staging license → $CONF_DIR/license.json"
  mkdir -p "$CONF_DIR"
  cp "$PARENT/.secrets/license.json" "$CONF_DIR/license.json"
  chmod 600 "$CONF_DIR/license.json"
fi
