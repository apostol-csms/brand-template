#!/usr/bin/env bash
#
# keys-init.sh — generate WireGuard keypairs (server + peer) into this
# directory before `docker compose up`.
#
# Usage:
#   ./keys-init.sh                   # generate server + 1 peer (10.10.1.2)
#   ./keys-init.sh --peers 10.10.1.{2..5}   # explicit peer IPs
#
# Idempotent: refuses to overwrite existing keys (operator deletes them
# manually if rotation is intended).

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

if ! command -v wg >/dev/null 2>&1; then
  echo "ERROR: wg CLI not found. Install wireguard-tools." >&2
  exit 1
fi

PEERS=("10.10.1.2")
if [[ "${1:-}" == "--peers" ]]; then
  shift
  PEERS=("$@")
fi

gen_pair() {
  local DIR="$1"
  mkdir -p "$DIR"
  if [[ -f "$DIR/privatekey" || -f "$DIR/publickey" ]]; then
    echo "skip: $DIR already has keys (rotate by deleting them first)"
    return 0
  fi
  ( umask 077; wg genkey > "$DIR/privatekey" )
  wg pubkey < "$DIR/privatekey" > "$DIR/publickey"
  echo "generated: $DIR/{privatekey,publickey}"
}

gen_pair "server"
for ip in "${PEERS[@]}"; do
  gen_pair "peers/$ip"
done

echo
echo "Done. Keys are gitignored — never commit them."
echo "Next: configure wg0.conf with the generated public keys."
