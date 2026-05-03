# db-migrate — one-shot container that applies platform/configuration patches
# before backend starts. Based on debian-slim + pgdg postgresql-client-18 to
# stay small (~80 MB) and keep the client version pinned to the server
# (postgres:latest used in .docker/postgres/Dockerfile — currently PG 18).
#
# Bumping PG major version: change postgresql-client-<N> below to match the
# server. No changes needed in migrate-crm.sh.
FROM debian:bookworm-slim

ENV DEBIAN_FRONTEND=noninteractive

RUN set -eux; \
    apt-get update; \
    apt-get install -y --no-install-recommends ca-certificates curl gnupg lsb-release; \
    install -d /usr/share/postgresql-common/pgdg; \
    curl -fsSL https://www.postgresql.org/media/keys/ACCC4CF8.asc \
        -o /usr/share/postgresql-common/pgdg/apt.postgresql.org.asc; \
    echo "deb [signed-by=/usr/share/postgresql-common/pgdg/apt.postgresql.org.asc] https://apt.postgresql.org/pub/repos/apt $(lsb_release -cs)-pgdg main" \
        > /etc/apt/sources.list.d/pgdg.list; \
    apt-get update; \
    apt-get install -y --no-install-recommends postgresql-client-18; \
    apt-get purge -y --auto-remove curl gnupg lsb-release; \
    rm -rf /var/lib/apt/lists/*

COPY migrate-crm.sh /migrate-crm.sh
RUN chmod +x /migrate-crm.sh

ENTRYPOINT ["bash", "/migrate-crm.sh"]
