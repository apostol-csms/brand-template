#!/usr/bin/env bash
set -euo pipefail

set -o allexport
source workdir/.env
set +o allexport

echo
read -r -p "Пересоздать базу данных? (y/N): " ans
if [[ "${ans}" != "y" && "${ans}" != "Y" ]]; then
  echo "Отмена."
  exit 0
fi

./docker-down.sh

docker volume rm -f "${PROJECT_NAME}"_postgresql

docker compose up -d --force-recreate postgres
docker compose logs -fn 500
