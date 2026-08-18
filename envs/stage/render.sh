#!/usr/bin/env bash
# envs/stage/render.sh — brand app-env renderer.
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

# Загрузка workdir/.env БЕЗ `source`.
#
# Здесь стояло `set -a; source "$WORKDIR/.env"; set +a`, и это работало
# ровно до первого значения с точкой с запятой. Брендовый знак приезжает
# инлайновым data:-URI:
#
#   BRANDING_MARK=data:image/svg+xml;base64,PHN2…
#
# bash разбирает такую строку как ДВЕ команды — `data:image/svg+xml` и
# `base64,PHN2…` — и вторая уходит в «command not found», exit 127. При
# `set -euo pipefail` это обрывает и install.sh, и update.sh на шаге
# render_app_env. Кавычки в шаблоне спасли бы от этого случая, но не от
# следующего: .env — формат данных, а не скрипт, и исполнять его нельзя
# в принципе. Разбираем построчно, без вычисления.
load_env() {
  local line key val
  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ -z "$line" || "$line" == \#* ]] && continue
    [[ "$line" != *=* ]] && continue
    key="${line%%=*}"
    val="${line#*=}"
    # Имя переменной должно быть именем переменной, иначе строка не наша.
    [[ "$key" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || continue
    # Снять обрамляющие кавычки, если они есть.
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
