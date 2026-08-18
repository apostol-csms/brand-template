#!/usr/bin/env bash
set -euo pipefail

set -o allexport
source workdir/.env
set +o allexport

docker compose down
