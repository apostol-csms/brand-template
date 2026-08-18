#!/usr/bin/env bash
set -euo pipefail

set -o allexport
source workdir/.env
set +o allexport

docker compose build

docker image list