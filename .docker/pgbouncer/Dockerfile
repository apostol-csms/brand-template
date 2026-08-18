# Плавающий тег upstream'а. Зеркалирующий бренд фиксирует его датой
# и подставляет полную ссылку через PGBOUNCER_IMAGE.
ARG PGBOUNCER_IMAGE=edoburu/pgbouncer:latest
FROM ${PGBOUNCER_IMAGE}

USER root

RUN apk add --no-cache gettext postgresql-client

COPY pgbouncer.ini.template userlist.txt /etc/pgbouncer/
COPY docker-entrypoint.sh /usr/local/bin/docker-entrypoint.sh

RUN set -eux; \
    chown postgres:root /etc/pgbouncer/userlist.txt && \
    chmod 640 /etc/pgbouncer/userlist.txt && \
    touch /etc/pgbouncer/pgbouncer.ini && \
    chown postgres:root /etc/pgbouncer/pgbouncer.ini && \
    chmod 640 /etc/pgbouncer/pgbouncer.ini && \
    chmod +x /usr/local/bin/docker-entrypoint.sh

USER postgres

ENTRYPOINT ["/usr/local/bin/docker-entrypoint.sh"]
