#!/usr/bin/env bash
#
# Remove the images built locally for this stack (<PROJECT_NAME>-*:
# nginx, pgbouncer, pgweb, landing). Platform images from the registry are
# left alone — they are shared and slow to pull again.
#
#   ./docker-image-rm.sh          ask for confirmation
#   ./docker-image-rm.sh --yes    skip the prompt

set -euo pipefail

cd "$(dirname "$0")"

ENV_FILE=workdir/.env
[[ -r "$ENV_FILE" ]] || { echo "No $ENV_FILE — stack not installed yet" >&2; exit 1; }

# sed, not `source` — see the comment in docker-new-database.sh.
PROJECT_NAME="$(sed -n 's/^PROJECT_NAME=//p' "$ENV_FILE" | tail -1 | tr -d '"')"
[[ -n "$PROJECT_NAME" ]] || { echo "PROJECT_NAME is not set in $ENV_FILE" >&2; exit 1; }

mapfile -t IMAGES < <(docker image list --format '{{.Repository}}:{{.Tag}}' \
                        | grep "^${PROJECT_NAME}-" || true)

if [[ ${#IMAGES[@]} -eq 0 ]]; then
  echo "No local '${PROJECT_NAME}-*' images."
  exit 0
fi

printf '%s\n' "${IMAGES[@]}"
if [[ "${1:-}" != "--yes" ]]; then
  echo
  read -r -p "Remove these ${#IMAGES[@]} images? (y/N): " ans
  if [[ "$ans" != "y" && "$ans" != "Y" ]]; then
    echo "Cancelled."
    exit 0
  fi
fi

for image in "${IMAGES[@]}"; do
  echo "Removing image: $image"
  docker image rm "$image"
done

docker image list
