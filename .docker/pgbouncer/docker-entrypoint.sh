#!/bin/sh
#
# pgbouncer entrypoint.
#   1. Render pgbouncer.ini from the template (envsubst).
#   2. Write userlist.txt — ONE line: the password of the `pgbouncer` auth role.
#   3. Exec pgbouncer.
#
# Why one line. userlist.txt used to be built from pg_authid, i.e. from the
# SCRAM verifiers of every application role. A verifier is enough to
# authenticate a client, but it cannot be used to log into the SERVER:
# pgbouncer answers «server login failed: wrong password type» and logs
# «password is SCRAM secret but client authentication did not provide SCRAM
# keys». The scheme worked while passwords were md5 and broke on PostgreSQL 18,
# where password_encryption defaults to scram-sha-256 — and since client
# authentication still succeeded, it looked like a password problem.
#
# Now the secret of an application role is fetched by query (auth_query, see
# pgbouncer.ini.template) through the SECURITY DEFINER function
# public.pgbouncer_get_auth, granted to the `pgbouncer` role only. No
# application-role verifiers remain in the container, no superuser takes part
# at runtime, and there is nothing to wait for postgres about at start-up.
#
# Required env:
#   DB_NAME             — database (for pgbouncer.ini)
#   DB_PASS_PGBOUNCER   — password of the `pgbouncer` role; the role is created
#                         by the database install (db/sql/pgbouncer.psql) from
#                         the very same value
# Optional:
#   PGBOUNCER_DEFAULT_POOL_SIZE, PGBOUNCER_MAX_DB_CONNECTIONS — pool sizing.
set -eu

export DB_NAME="${DB_NAME:-csms}"
# Pool sizing. Keep max_db_connections below postgres' max_connections minus
# what connects directly (apibot) — see pgbouncer.ini.template.
export PGBOUNCER_DEFAULT_POOL_SIZE="${PGBOUNCER_DEFAULT_POOL_SIZE:-50}"
export PGBOUNCER_MAX_DB_CONNECTIONS="${PGBOUNCER_MAX_DB_CONNECTIONS:-100}"

envsubst '$DB_NAME $PGBOUNCER_DEFAULT_POOL_SIZE $PGBOUNCER_MAX_DB_CONNECTIONS' \
  < /etc/pgbouncer/pgbouncer.ini.template \
  > /etc/pgbouncer/pgbouncer.ini

if [ -z "${DB_PASS_PGBOUNCER:-}" ]; then
  echo "pgbouncer: DB_PASS_PGBOUNCER is not set — authentication cannot work" >&2
  exit 1
fi

# Truncate-in-place (cat > file) rather than mv/cp: when userlist.txt arrives
# as a single-file bind-mount, neither `mv` nor busybox `cp -f` can replace the
# mount target, while opening the existing file for write can.
printf '"pgbouncer" "%s"\n' "$DB_PASS_PGBOUNCER" > /etc/pgbouncer/userlist.txt
chmod 640 /etc/pgbouncer/userlist.txt

exec pgbouncer /etc/pgbouncer/pgbouncer.ini
