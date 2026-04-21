#!/usr/bin/env bash
# hooks/pre-install.sh
#
# Called by install.sh AFTER secrets are loaded but BEFORE `docker
# compose build`. Use this for brand-specific setup that must happen
# before images build:
#   - Provisioning external DNS / load-balancer entries
#   - Sending a "deployment started" notification to Slack
#   - Seeding external config (Vault, KV stores)
#   - Pre-creating database volumes, backup targets
#
# Env vars available:
#   WORKDIR           absolute path to workdir/ (.env, db/, frontend/)
#   BRAND_ENV         dev | stage | prod
#   PLATFORM_VERSION  pinned semver (e.g. 1.3.7 or 0.9.0-alpha)
#
# Per-env override: envs/<env>/hooks/pre-install.sh runs in addition
# to this one (if it exists).
#
# Exit non-zero to abort the install.

set -euo pipefail

# No-op stub. Replace with brand-specific logic.
exit 0
