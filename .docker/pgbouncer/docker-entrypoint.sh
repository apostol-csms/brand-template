#!/bin/sh
#
# pgbouncer entrypoint.
#   1. Render pgbouncer.ini from template (envsubst on $DB_NAME).
#   2. Regenerate userlist.txt from postgres pg_authid so that password
#      hashes match whatever postgres created (PG18 defaults to
#      SCRAM-SHA-256 — previous static MD5 userlist no longer works).
#   3. Exec pgbouncer.
#
# Required env (via compose env_file / environment:):
#   DB_NAME                  — target database (for pgbouncer.ini)
#   PGBOUNCER_PG_HOST        — postgres host (default: postgres)
#   PGBOUNCER_PG_PORT        — postgres port (default: 5432)
#   PGBOUNCER_SUPERUSER      — postgres role with read on pg_authid
#                              (default: postgres)
#   PGBOUNCER_SUPERPASSWORD  — its password (fallback: $POSTGRES_PASSWORD)
#
# If no superuser credentials are present, the script falls back to the
# static userlist.txt baked into the image (legacy behaviour).
set -eu

export DB_NAME="${DB_NAME:-csms}"
# Pool sizing. Keep max_db_connections below postgres' max_connections minus
# what connects directly (apibot) — see pgbouncer.ini.template.
export PGBOUNCER_DEFAULT_POOL_SIZE="${PGBOUNCER_DEFAULT_POOL_SIZE:-50}"
export PGBOUNCER_MAX_DB_CONNECTIONS="${PGBOUNCER_MAX_DB_CONNECTIONS:-100}"

envsubst '$DB_NAME $PGBOUNCER_DEFAULT_POOL_SIZE $PGBOUNCER_MAX_DB_CONNECTIONS' \
  < /etc/pgbouncer/pgbouncer.ini.template \
  > /etc/pgbouncer/pgbouncer.ini

PGHOST="${PGBOUNCER_PG_HOST:-postgres}"
PGPORT="${PGBOUNCER_PG_PORT:-5432}"
SUPERUSER="${PGBOUNCER_SUPERUSER:-postgres}"
SUPERPASS="${PGBOUNCER_SUPERPASSWORD:-${POSTGRES_PASSWORD:-}}"

if [ -n "$SUPERPASS" ]; then
  echo "pgbouncer: waiting for postgres at $PGHOST:$PGPORT"
  tries=60
  until PGPASSWORD="$SUPERPASS" psql -h "$PGHOST" -p "$PGPORT" \
      -U "$SUPERUSER" -d postgres -c '\q' >/dev/null 2>&1; do
    tries=$((tries - 1))
    if [ "$tries" -le 0 ]; then
      echo "pgbouncer: postgres unreachable after 60s — aborting" >&2
      exit 1
    fi
    sleep 1
  done

  echo "pgbouncer: regenerating userlist.txt from pg_authid"
  PGPASSWORD="$SUPERPASS" psql -h "$PGHOST" -p "$PGPORT" \
      -U "$SUPERUSER" -d postgres -tAq \
      -c "SELECT '\"' || rolname || '\" \"' || rolpassword || '\"'
          FROM pg_authid
          WHERE rolcanlogin AND rolpassword IS NOT NULL
          ORDER BY rolname" \
    > /etc/pgbouncer/userlist.txt.new
  # Use cp -f instead of mv: when /etc/pgbouncer/userlist.txt is a
  # single-file bind-mount (brand compose maps workdir/pgbouncer/userlist.txt
  # over it for host-side regen by hooks/post-install.sh), `mv` fails with
  # "Resource busy" because it tries to unlink the mount target.  cp
  # truncates + writes in place and works regardless of whether the file
  # is bind-mounted or part of the image's writable layer.
  cat /etc/pgbouncer/userlist.txt.new > /etc/pgbouncer/userlist.txt
  rm -f /etc/pgbouncer/userlist.txt.new
  chmod 640 /etc/pgbouncer/userlist.txt
else
  echo "pgbouncer: no superuser password set — using static userlist.txt" >&2
fi

exec pgbouncer /etc/pgbouncer/pgbouncer.ini
