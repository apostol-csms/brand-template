#!/usr/bin/env bash
# envs/dev/render.sh — brand app-env renderer.
#
# Renders runtime env files from envs/templates/** via envsubst + workdir/.env.
# The logic is identical for dev/stage/prod — only values differ, and they
# come from workdir/.env (merged: root .env.template + envs/<env>/.env.template
# + .secrets/<env>.env).
#
# Landing is rendered separately in hooks/pre-install.sh (sibling repo, not
# under workdir/).

set -euo pipefail

: "${WORKDIR:?WORKDIR required}"
: "${SCRIPT_DIR:?SCRIPT_DIR required}"

TEMPLATES_DIR="$SCRIPT_DIR/envs/templates"

# Load workdir/.env WITHOUT `source`.
#
# This used to be `set -a; source "$WORKDIR/.env"; set +a`, which worked
# right up to the first value containing a semicolon. Brand artwork
# arrives as an inline data: URI:
#
#   BRANDING_MARK=data:image/svg+xml;base64,PHN2…
#
# bash reads that as TWO commands — `data:image/svg+xml` and
# `base64,PHN2…` — and the second one exits 127, command not found. Under
# `set -euo pipefail` that aborts both install.sh and update.sh at the
# render_app_env step. Quoting the value would fix this one case but not
# the next: .env is a data format, not a script, and must not be executed
# at all — it holds every database role password and the OAuth2 secrets.
# Parse it line by line instead, with no evaluation.
load_env() {
  local line key val
  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ -z "$line" || "$line" == \#* ]] && continue
    [[ "$line" != *=* ]] && continue
    key="${line%%=*}"
    val="${line#*=}"
    # A variable name must look like one, otherwise the line is not ours.
    [[ "$key" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || continue
    # Strip surrounding quotes if present.
    if [[ ${#val} -ge 2 ]]; then
      case "$val" in
        \"*\") val="${val:1:${#val}-2}" ;;
        \'*\') val="${val:1:${#val}-2}" ;;
      esac
    fi
    export "$key=$val"
  done < "$1"
}

load_env "$WORKDIR/.env"

render() {
  local src="$TEMPLATES_DIR/$1" dst="$WORKDIR/$2"
  if [[ ! -f "$src" ]]; then
    echo "WARN: $src missing — skipping" >&2
    return 0
  fi
  mkdir -p "$(dirname "$dst")"
  envsubst < "$src" > "$dst"
  chmod 600 "$dst"
  echo "  render $dst"
}

render backend/db/sql/.env.psql.template           db/sql/.env.psql
render backend/db/sql/.env.key.psql.template       db/sql/.env.key.psql
render backend/db/sql/.env.branding.psql.template  db/sql/.env.branding.psql
render frontend/webapp/.env.production.template    frontend/webapp/.env.production
render frontend/driver/.env.template               frontend/driver/.env
render frontend/pay/.env.template                  frontend/pay/.env
