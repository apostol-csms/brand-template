#!/usr/bin/env bash
# hooks/pre-install.sh
#
# Called by install.sh AFTER secrets are loaded but BEFORE
# `docker compose build`. Stages operator-supplied artefacts from the
# sibling .secrets/ directory into the locations that compose/Dockerfile
# expect:
#
#   .secrets/letsencrypt/  → csms/.docker/nginx-certbot/certbot/letsencrypt/
#         Dockerfile bakes this directory into the nginx image at build
#         time (`COPY ./certbot/letsencrypt /etc/letsencrypt`). The
#         runtime named volume `letsencrypt:` bootstraps from those
#         baked contents on first start; subsequent renewals write back
#         into the volume. Symlink does NOT work — Docker refuses to
#         follow symlinks outside the build context.
#
#   .secrets/license.json  → csms/conf/license.json (license-aware brands)
#         Mounted into backend + db-init containers as :ro. Carries
#         brand identity (project.* / branding.*), `db_key_wrapped`
#         (Phase 4c), and accepted_binary_hashes. If absent for a
#         pre-license brand (no conf/license.json.example in repo),
#         this step is skipped.
#
# Brands extend this hook in-repo for additional pre-build setup
# (sibling repo clones — landing/, third-party API provisioning,
# Slack notifications, etc.).
#
# Env vars available:
#   WORKDIR           absolute path to workdir/ (.env, db/, frontend/)
#   BRAND_ENV         dev | stage | prod
#   PLATFORM_VERSION  pinned semver (e.g. 1.4.0 or 0.10.0-alpha)
#
# Per-env override: envs/<env>/hooks/pre-install.sh runs in addition
# to this one (if it exists).
#
# Exit non-zero to abort the install. install.sh's preflight asserts
# the .secrets/ artefacts are present, so this hook treats their
# presence as a precondition (no defensive re-checks).

set -euo pipefail

: "${WORKDIR:?WORKDIR required}"

SCRIPT_DIR="$(dirname "$WORKDIR")"      # brand-repo root: .../<brand>/csms
PARENT="$(dirname "$SCRIPT_DIR")"       # .../<brand> — sibling of .secrets/

# ─── Stage TLS into nginx build context ─────────────────────────────
#
# nginx-certbot's Dockerfile expects ./certbot/letsencrypt/ relative
# to its build context (.docker/nginx-certbot/). On a fresh server the
# .secrets/letsencrypt/ tree was placed there once by the admin (see
# brand-deployment-runbook §5.5).
CERTBOT_CTX="$SCRIPT_DIR/.docker/nginx-certbot/certbot/letsencrypt"
echo "hook/pre-install: staging SSL → $CERTBOT_CTX"
mkdir -p "$(dirname "$CERTBOT_CTX")"
rm -rf "$CERTBOT_CTX"
cp -a "$PARENT/.secrets/letsencrypt" "$CERTBOT_CTX"

# ─── Stage license.json for compose mount (license-aware brands) ─────
#
# docker-compose.yaml mounts ./conf/license.json into backend +
# db-init as :ro. Source comes from ../.secrets/ (operator vault /
# CI-delivered Secret).
if [[ -f "$PARENT/.secrets/license.json" ]]; then
  CONF_DIR="$SCRIPT_DIR/conf"
  echo "hook/pre-install: staging license → $CONF_DIR/license.json"
  mkdir -p "$CONF_DIR"
  cp "$PARENT/.secrets/license.json" "$CONF_DIR/license.json"
  chmod 600 "$CONF_DIR/license.json"
fi

# ─── Empty placeholder for pgbouncer userlist bind-mount ─────────────
#
# docker-compose.yaml bind-mounts ./workdir/pgbouncer/userlist.txt
# into pgbouncer at /etc/pgbouncer/userlist.txt.  Compose errors out
# at `up` time if the source file is missing — even when downstream
# post-install.sh would overwrite it with real SCRAM hashes.  Touch
# an empty file here so the bind-mount succeeds; pgbouncer comes up
# auth-empty until post-install rewrites and restarts it.
USERLIST="$WORKDIR/pgbouncer/userlist.txt"
mkdir -p "$(dirname "$USERLIST")"
[[ -f "$USERLIST" ]] || : > "$USERLIST"
chmod 600 "$USERLIST"
