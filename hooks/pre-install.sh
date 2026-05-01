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

# ─── Self-heal SSL shared configs ──────────────────────────────────
#
# certbot --nginx / --apache plugins drop options-ssl-nginx.conf and
# ssl-dhparams.pem in /etc/letsencrypt/ at first run; certonly --
# standalone does NOT. nginx default.conf.template `include`s both,
# so without them nginx fails to start with "open() … No such file
# or directory". Generate them ourselves if absent — one-time cost
# at install, reproduces the canonical certbot output.
if [[ ! -f "$CERTBOT_CTX/options-ssl-nginx.conf" ]]; then
  echo "hook/pre-install: synthesising options-ssl-nginx.conf"
  cat > "$CERTBOT_CTX/options-ssl-nginx.conf" <<'NGINX_SSL'
# This file contains important security parameters. Synthesised by
# pre-install.sh to match the canonical certbot --nginx artefact —
# safe to overwrite on the next deploy.
# Contents based on https://ssl-config.mozilla.org

ssl_session_cache shared:le_nginx_SSL:10m;
ssl_session_timeout 1440m;
ssl_session_tickets off;

ssl_protocols TLSv1.2 TLSv1.3;
ssl_prefer_server_ciphers off;

ssl_ciphers "ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384:ECDHE-ECDSA-CHACHA20-POLY1305:ECDHE-RSA-CHACHA20-POLY1305:DHE-RSA-AES128-GCM-SHA256:DHE-RSA-AES256-GCM-SHA384";
NGINX_SSL
fi
if [[ ! -f "$CERTBOT_CTX/ssl-dhparams.pem" ]]; then
  echo "hook/pre-install: synthesising ssl-dhparams.pem (RFC 7919 ffdhe2048)"
  # ffdhe2048 from RFC 7919 — vetted, widely-used, faster than running
  # `openssl dhparam` (which would take 30–60 seconds at install time).
  cat > "$CERTBOT_CTX/ssl-dhparams.pem" <<'DHPARAM'
-----BEGIN DH PARAMETERS-----
MIIBCAKCAQEA//////////+t+FRYortKmq/cViAnPTzx2LnFg84tNpWp4TZBFGQz
+8yTnc4kmz75fS/jY2MMddj2gbICrsRhetPfHtXV/WVhJDP1H18GbtCFY2VVPe0a
87VXE15/V8k1mE8McODmi3fipona8+/och3xWKE2rec1MKzKT0g6eXq8CrGCsyT7
YdEIqUuyyOP7uWrat2DX9GgdT0Kj3jlN9K5W7edjcrsZCwenyO4KbXCeAvzhzffi
7MA0BM0oNC9hkXL+nOmFg/+OTxIy7vKBg8P+OxtMb61zO7X8vC7CIAXFjvGDfRaD
ssbzSibBsu/6iGtCOGEoXJf//////////wIBAg==
-----END DH PARAMETERS-----
DHPARAM
fi

# ─── Multi-SAN cert support (one cert covering all subdomains) ──────
#
# default.conf.template ssl_certificate paths use per-subdomain
# /etc/letsencrypt/live/<sub>.${DOMAIN}/fullchain.pem. That works when
# every subdomain has its own cert directory (legacy chargemecar / OCPP
# CSS layout). New deployments often use ONE multi-SAN cert covering
# every subdomain — only /etc/letsencrypt/live/${DOMAIN}/ exists, and
# nginx fails to start because cloud.<domain>/, driver.<domain>/, etc.
# don't exist.
#
# Detect that case (one real cert dir, multiple SANs) and create
# symlinks <sub>.${DOMAIN} → ${DOMAIN} in the build context. Symlinks
# stay relative inside the staging directory, so cp -a / docker COPY
# preserve them and nginx resolves them at runtime.
LIVE_DIR="$CERTBOT_CTX/live"
if [[ -d "$LIVE_DIR" ]]; then
  # Need a DOMAIN to know what the apex cert dir is called.
  # workdir/.env is built earlier in install.sh — load it.
  if [[ -f "$WORKDIR/.env" ]] && grep -qE '^DOMAIN=' "$WORKDIR/.env"; then
    DOMAIN="$(grep -E '^DOMAIN=' "$WORKDIR/.env" | head -1 | cut -d= -f2-)"
    DOMAIN="${DOMAIN%\"}"; DOMAIN="${DOMAIN#\"}"   # strip quotes
  fi

  if [[ -n "${DOMAIN:-}" && -d "$LIVE_DIR/$DOMAIN" ]]; then
    # Pull the SAN list from the cert. Only subdomains of $DOMAIN are
    # candidates — cross-domain SANs (e.g. ${ALT_DOMAIN}) get separate
    # cert dirs anyway.
    SANS="$(openssl x509 -in "$LIVE_DIR/$DOMAIN/cert.pem" -noout -ext subjectAltName 2>/dev/null \
      | tr ',' '\n' \
      | sed -nE 's|.*DNS:([^ ]+).*|\1|p')"

    SYMLINKED=()
    while IFS= read -r san; do
      [[ -z "$san" || "$san" == "$DOMAIN" ]] && continue
      [[ "$san" != *".$DOMAIN" ]] && continue          # only sub-of-DOMAIN
      [[ -e "$LIVE_DIR/$san" ]] && continue            # already exists
      ln -sfn "$DOMAIN" "$LIVE_DIR/$san"
      SYMLINKED+=("$san")
    done <<< "$SANS"

    if [[ ${#SYMLINKED[@]} -gt 0 ]]; then
      echo "hook/pre-install: multi-SAN cert at live/$DOMAIN/ — symlinked ${#SYMLINKED[@]} subdomains:"
      printf '  → %s\n' "${SYMLINKED[@]}"
    fi
  fi
fi

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
