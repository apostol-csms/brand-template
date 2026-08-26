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

# ─── pgbouncer auth role ─────────────────────────────────────────────
#
# Runs BEFORE the rolling restart, and that is the whole point. From this
# version pgbouncer authenticates through auth_query (see
# .docker/pgbouncer/pgbouncer.ini.template) and needs a `pgbouncer` role plus
# the public.pgbouncer_get_auth function in the database. On a fresh install
# both are created by db/sql/pgbouncer.psql; an update never re-runs
# kernel.psql, so on an existing deployment they have to be created here.
#
# Without this the new pgbouncer starts against a database that has no such
# role, auth_query fails, and EVERY connection is rejected — the whole stack
# goes down. Aborting the update instead is the cheaper outcome.

: "${WORKDIR:?WORKDIR required}"
COMPOSE="docker compose --env-file $WORKDIR/.env"

# workdir/.env — это env_file для Docker, а НЕ сценарий оболочки. Docker берёт
# всё после первого `=` буквально, поэтому значение законно может содержать
# `;`, пробелы, кавычки и `$`. Исполнять такой файл через `.` нельзя: на
# ocpp-css строка `BRANDING_MARK=data:image/svg+xml;base64,…` разрезалась по
# `;`, хвост ушёл в оболочку как команда, и обновление встало.
#
# Читаем только нужные ключи и берём ПОСЛЕДНЕЕ вхождение — именно его берёт
# Docker, потому что install.sh не сливает шаблоны, а склеивает корневой с
# посредовым, и приоритет держится порядком строк.
env_get() {
    sed -n "s/^$1=//p" "$WORKDIR/.env" | tail -1
}

DB_PASS_PGBOUNCER="$(env_get DB_PASS_PGBOUNCER)"
PGDATABASE="$(env_get PGDATABASE)"

if [[ -z "${DB_PASS_PGBOUNCER:-}" ]]; then
    echo "hook/pre-update: DB_PASS_PGBOUNCER is not set in $WORKDIR/.env." >&2
    echo "hook/pre-update: add it (any strong value) and re-run; pgbouncer" >&2
    echo "hook/pre-update: cannot authenticate without it." >&2
    exit 1
fi

echo "hook/pre-update: ensuring pgbouncer auth role"
# Пароль передаётся psql-переменной: :'pgbpass' экранируется самим psql.
# Подстановка значения прямо в текст SQL сломалась бы на кавычке в пароле.
#
# Но внутрь DO-блока переменную передаёт GUC, а не :'pgbpass' напрямую: psql
# НЕ подставляет свои переменные внутри dollar-quoted строки, и написанное там
# :'pgbpass' доезжает до сервера буквально — `syntax error at or near ":"`.
# Тем же приёмом это решено в db/sql/pgbouncer.psql (там и комментарий).
$COMPOSE exec -T postgres psql -v ON_ERROR_STOP=1 -U postgres \
    -d "${PGDATABASE:-csms}" -v pgbpass="$DB_PASS_PGBOUNCER" <<SQL
SELECT set_config('password.pgbouncer', :'pgbpass', false);

DO \$\$
DECLARE
  vPassword text := coalesce(current_setting('password.pgbouncer', true), '');
BEGIN
  IF vPassword = '' THEN
    RAISE EXCEPTION 'hook/pre-update: пароль роли pgbouncer пуст — проверь DB_PASS_PGBOUNCER в workdir/.env';
  END IF;

  IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'pgbouncer') THEN
    EXECUTE format('CREATE ROLE pgbouncer LOGIN PASSWORD %L', vPassword);
  ELSE
    EXECUTE format('ALTER ROLE pgbouncer LOGIN PASSWORD %L', vPassword);
  END IF;
END
\$\$;

CREATE OR REPLACE FUNCTION public.pgbouncer_get_auth (pUsername text)
RETURNS TABLE (usename text, passwd text) AS \$\$
  SELECT usename::text, passwd::text FROM pg_catalog.pg_shadow WHERE usename = pUsername;
\$\$ LANGUAGE SQL SECURITY DEFINER STABLE SET search_path = pg_catalog, pg_temp;

REVOKE ALL ON FUNCTION public.pgbouncer_get_auth(text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.pgbouncer_get_auth(text) TO pgbouncer;
GRANT CONNECT ON DATABASE "${PGDATABASE:-csms}" TO pgbouncer;
SQL

echo "hook/pre-update: pgbouncer auth role ready"

exit 0
