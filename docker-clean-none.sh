#!/usr/bin/env bash
#
# Remove dangling (<none>) images — layers left behind by rebuilds. Not
# brand-scoped: this cleans the whole Docker host.
#
#   ./docker-clean-none.sh          ask for confirmation
#   ./docker-clean-none.sh --yes    skip the prompt

set -euo pipefail

cd "$(dirname "$0")"

echo "Dangling images (<none>):"
docker images -f "dangling=true"

if [[ -z "$(docker images -q -f 'dangling=true')" ]]; then
  echo "Nothing to remove."
  exit 0
fi

if [[ "${1:-}" != "--yes" ]]; then
  echo
  read -r -p "Remove ALL of these images? (y/N): " ans
  if [[ "$ans" != "y" && "$ans" != "Y" ]]; then
    echo "Cancelled."
    exit 0
  fi
fi

docker rmi $(docker images -q -f "dangling=true") 2>/dev/null || true

echo "Done. Dangling images left:"
docker images -f "dangling=true"
