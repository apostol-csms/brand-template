#!/usr/bin/env bash
# hooks/post-install.sh
#
# Called by install.sh AFTER `docker compose up -d` but BEFORE the
# final check.sh verification. Use for:
#   - Smoke-testing a specific brand workflow (create demo user, fire
#     a test charging session, issue a test payment)
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

exit 0
