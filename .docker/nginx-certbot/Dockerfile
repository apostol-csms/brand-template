# Базовый образ Nginx
# Реестр базового образа параметризован: по умолчанию Docker Hub,
# бренд с собственным зеркалом подставляет своё через BASE_REGISTRY.
ARG BASE_REGISTRY=docker.io/library
FROM ${BASE_REGISTRY}/nginx:stable-bookworm

# Установка необходимых пакетов
RUN apt-get update && apt-get install -y \
    certbot \
    python3-certbot-nginx \
    gettext-base \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/*

# Создание необходимых директорий
RUN mkdir /var/nginx; \
    mkdir /var/nginx/client_body_temp; \
    mkdir /var/nginx/proxy_temp; \
    mkdir /var/www; \
    mkdir /var/www/certbot; \
    mkdir /var/www/frontend; \
    mkdir /var/www/oauth; #legacy, kept for directory structure

# Копирование SSL сертификатов
COPY ./certbot/letsencrypt /etc/letsencrypt

# Копирование конфигурации Nginx
COPY ./nginx.conf /etc/nginx/nginx.conf
COPY ./default.conf.template /etc/nginx/conf.d/default.conf.template
COPY ./includes/ /etc/nginx/includes/

# Копирование Swagger UI / API docs
COPY ./frontend/docs /var/www/docs

# Копирование сайтов
COPY ./frontend /var/www/frontend
# Auth frontend is now a separate container (auth service)
# COPY ./oauth /var/www/oauth

RUN chown root:www-data -R /var/www

COPY ./entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

ENTRYPOINT ["/entrypoint.sh"]
