#!/usr/bin/env bash
# hooks/post-update.sh
#
# Called by update.sh AFTER the rolling restart, BEFORE check.sh.
# Use for:
#   - Disabling the maintenance banner
#   - Re-enabling external webhooks paused in pre-update
#   - Running version-specific data fix-ups (e.g., one-time scripts
#     documented in MIGRATION.md)
#   - Sending "update complete" notifications
#
# Env vars available:
#   WORKDIR           absolute path to workdir/
#   BRAND_ENV         dev | stage | prod
#   PLATFORM_VERSION  newly installed version
#
# Per-env override: envs/<env>/hooks/post-update.sh runs in addition.

set -euo pipefail

exit 0
