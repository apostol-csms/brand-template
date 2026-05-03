# Базовый образ postgres
FROM postgres:latest

ENV TZ=Europe/Moscow
ENV LANG=en_US.UTF-8
ENV LC_ALL=en_US.UTF-8

# Настройка часового пояса и локалей
RUN set -eux; \
    echo $TZ > /etc/timezone; \
    echo "en_US.UTF-8 UTF-8" > /etc/locale.gen; \
    echo "ru_RU.UTF-8 UTF-8" >> /etc/locale.gen; \
    apt update && apt install -y --no-install-recommends \
        tzdata locales ca-certificates iproute2 iputils-ping git && \
    ln -snf /usr/share/zoneinfo/$TZ /etc/localtime && \
    dpkg-reconfigure -f noninteractive tzdata && \
    dpkg-reconfigure -f noninteractive locales && \
    apt-get clean && rm -rf /var/lib/apt/lists/*;

# Copy SQL into the image. Brand config files (.env.psql, .env.key.psql,
# .env.branding.psql) must be placed directly in backend/db/sql/ on the
# host before building (e.g. via brand/apply.sh). They travel into the
# image via this COPY and are loaded at init time by sets.psql.
COPY ./backend/db/sql /docker-entrypoint-initdb.d
COPY ./.docker/postgres/postgresql.conf /tmp
COPY ./tmp /tmp

USER root

RUN set -eux; \
    git config --global --add safe.directory /docker-entrypoint-initdb.d/platform; \
    chown postgres:root -R /docker-entrypoint-initdb.d && \
    chmod 774 /docker-entrypoint-initdb.d && \
    chmod +x /docker-entrypoint-initdb.d/00-bootstrap.sh && \
    chmod +x /docker-entrypoint-initdb.d/01-init.sh;

USER postgres