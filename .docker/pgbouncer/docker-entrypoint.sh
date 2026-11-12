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
#   PG_UPSTREAM_HOST, PG_UPSTREAM_PORT — the database behind the pooler (default postgres:5432).
set -eu

export DB_NAME="${DB_NAME:-csms}"
# Pool sizing. max_db_connections is never below 200. Keep it
# below postgres' max_connections minus what connects directly (apibot, ~64) and
# superuser_reserved_connections (3) — so max_connections has to be raised
# (PG_MAX_CONNECTIONS) on a host that runs the stock 200. See pgbouncer.ini.template.
# default_pool_size is 150: it is per (database, role), and the ocpp role alone needs
# N_cs x CS_WORKERS x (CS_POOL_MAX + 1) server connections (3x4 red at 50, green at 150). Keep it
# >= 1.2 x that ceiling; max_db_connections still caps the sum over the roles.
export PGBOUNCER_DEFAULT_POOL_SIZE="${PGBOUNCER_DEFAULT_POOL_SIZE:-150}"
export PGBOUNCER_MAX_DB_CONNECTIONS="${PGBOUNCER_MAX_DB_CONNECTIONS:-200}"
# Where the pooler logs in. Defaults are the compose service `postgres`; an external database or a
# balancer in front of a cluster (HAProxy :5000) is set in workdir/.env: PG_UPSTREAM_HOST / PG_UPSTREAM_PORT.
export PG_UPSTREAM_HOST="${PG_UPSTREAM_HOST:-postgres}"
export PG_UPSTREAM_PORT="${PG_UPSTREAM_PORT:-5432}"

envsubst '$DB_NAME $PGBOUNCER_DEFAULT_POOL_SIZE $PGBOUNCER_MAX_DB_CONNECTIONS $PG_UPSTREAM_HOST $PG_UPSTREAM_PORT' \
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
