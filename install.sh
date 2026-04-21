#!/usr/bin/env bash
#
# install.sh — initial brand deployment on a fresh server.
#
# Usage:
#   ./install.sh --env=<dev|stage|prod> [--force] [--dry-run]
#
# Or one-liner (reads BRAND_REPO_URL from env, clones, re-execs):
#   curl -fsSL https://raw.githubusercontent.com/<brand>/csms/main/install.sh \
#     | BRAND_ENV=prod BRAND_REPO_URL=https://github.com/<brand>/csms bash
#
# Pipeline:
#   1. Self-bootstrap (git clone if run via pipe)
#   2. Pre-flight:     docker ≥24, compose v2, disk ≥20 GB, RAM ≥4 GB
#   3. Platform pin:   read envs/<env>/platform.lock.json → PLATFORM_VERSION
#   4. Merge env:      .env.template + envs/<env>/.env.template → workdir/.env
#   5. Load secrets:   envs/<env>/secrets/load-from-vault.sh writes into workdir/
#   6. Clone sources:  apostol-csms/{db,frontend} at pinned tag → workdir/
#   7. Pull images:    csms-backend + csms-ocpp from GHCR (public, no auth)
#   8. Pre-install hook
#   9. Local build:    docker compose build (db-init + 4 frontend apps + infra)
#  10. First boot:     postgres → db-init → db-migrate → rest
#  11. Post-install hook
#  12. ./check.sh
#
# Idempotency: refuses if workdir/ exists unless --force is set.

set -euo pipefail

# ─── Globals ─────────────────────────────────────────────────────────

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKDIR="$SCRIPT_DIR/workdir"
REQUIRED_DOCKER_MAJOR=24
MIN_DISK_GB=20
MIN_RAM_MB=4096

BRAND_ENV="${BRAND_ENV:-}"
BRAND_REPO_URL="${BRAND_REPO_URL:-}"
FORCE=0
DRY_RUN=0

# ─── Logging ─────────────────────────────────────────────────────────

if [[ -t 1 ]]; then
  C_GREEN=$'\033[32m'; C_RED=$'\033[31m'; C_YELLOW=$'\033[33m'; C_RESET=$'\033[0m'
else
  C_GREEN=; C_RED=; C_YELLOW=; C_RESET=
fi

log()  { printf '%s[install]%s %s\n' "$C_GREEN"  "$C_RESET" "$*"; }
warn() { printf '%s[install] WARN:%s %s\n' "$C_YELLOW" "$C_RESET" "$*" >&2; }
err()  { printf '%s[install] ERROR:%s %s\n' "$C_RED"   "$C_RESET" "$*" >&2; }
run()  { if [[ $DRY_RUN -eq 1 ]]; then echo "[dry-run] $*"; else "$@"; fi; }

# ─── Help ────────────────────────────────────────────────────────────

display_help() {
  cat <<EOF
Apostol CSMS brand installer.

Usage:
  ./install.sh --env=<dev|stage|prod> [options]

Options:
  --env=<name>   Target environment (required unless BRAND_ENV is set)
  --force        Bypass 'workdir/ already exists' check
  --dry-run      Print planned actions without executing
  -h, --help     This message

Env vars:
  BRAND_ENV          Alternative to --env=
  BRAND_REPO_URL     Git URL of the brand repo (for self-bootstrap)
  BRAND_INSTALL_DIR  Clone destination when self-bootstrapping
                     (default: /opt/<repo-basename>)
EOF
}

# ─── Arg parsing ─────────────────────────────────────────────────────

for ARG in "$@"; do
  case "$ARG" in
    --env=*)   BRAND_ENV="${ARG#*=}" ;;
    --force)   FORCE=1 ;;
    --dry-run) DRY_RUN=1 ;;
    -h|--help) display_help; exit 0 ;;
    *) err "Unknown argument: $ARG"; display_help >&2; exit 1 ;;
  esac
done

# ─── Step 1: Self-bootstrap ──────────────────────────────────────────
#
# If the script was run via curl|bash ($0 ends in "bash" or is not a file),
# git clone the brand repo and re-exec from there.

self_bootstrap() {
  # Heuristic: BASH_SOURCE[0] is empty/non-file when run from stdin.
  if [[ -f "${BASH_SOURCE[0]:-/dev/null}" ]]; then
    return 0   # Already running from a file — skip bootstrap.
  fi
  if [[ -z "$BRAND_REPO_URL" ]]; then
    err "Pipe install detected but BRAND_REPO_URL is unset. Set BRAND_REPO_URL=https://github.com/<brand>/csms and retry."
    exit 1
  fi
  local BASENAME; BASENAME="$(basename "$BRAND_REPO_URL" .git)"
  local DEST="${BRAND_INSTALL_DIR:-/opt/$BASENAME}"
  log "self-bootstrap: clone $BRAND_REPO_URL → $DEST"
  if [[ -d "$DEST" && $FORCE -eq 0 ]]; then
    err "$DEST already exists. cd there and run ./install.sh, or remove it."
    exit 1
  fi
  run git clone "$BRAND_REPO_URL" "$DEST"
  cd "$DEST"
  exec bash "$DEST/install.sh" "$@"
}

# ─── Step 2: Pre-flight ──────────────────────────────────────────────

preflight() {
  log "pre-flight checks"

  if ! command -v docker >/dev/null 2>&1; then
    err "docker not found"; exit 1
  fi
  local DV DMAJOR
  DV="$(docker --version | awk '{print $3}' | tr -d ,)"
  DMAJOR="${DV%%.*}"
  if [[ "$DMAJOR" -lt $REQUIRED_DOCKER_MAJOR ]]; then
    err "Docker ≥${REQUIRED_DOCKER_MAJOR} required (found $DV)"; exit 1
  fi

  if ! docker compose version >/dev/null 2>&1; then
    err "docker compose v2 not found"; exit 1
  fi

  local DISK_GB
  DISK_GB="$(df -BG "$SCRIPT_DIR" | awk 'NR==2 {gsub(/G/,"",$4); print $4}')"
  if [[ "$DISK_GB" -lt $MIN_DISK_GB ]]; then
    err "Need ≥${MIN_DISK_GB} GB free disk, got $DISK_GB GB"; exit 1
  fi

  local RAM_MB
  RAM_MB="$(awk '/MemAvailable:/ {print int($2/1024)}' /proc/meminfo 2>/dev/null || echo 0)"
  if [[ "$RAM_MB" -gt 0 && "$RAM_MB" -lt $MIN_RAM_MB ]]; then
    warn "Less than ${MIN_RAM_MB} MB RAM available (got $RAM_MB MB)"
  fi

  for tool in git jq envsubst curl; do
    command -v "$tool" >/dev/null 2>&1 || { err "$tool not found"; exit 1; }
  done

  if [[ ! -d "$SCRIPT_DIR/envs/$BRAND_ENV" ]]; then
    err "envs/$BRAND_ENV/ not found"; exit 1
  fi
  if [[ ! -f "$SCRIPT_DIR/envs/$BRAND_ENV/platform.lock.json" ]]; then
    err "envs/$BRAND_ENV/platform.lock.json not found"; exit 1
  fi
  if [[ ! -x "$SCRIPT_DIR/envs/$BRAND_ENV/secrets/load-from-vault.sh" ]]; then
    err "envs/$BRAND_ENV/secrets/load-from-vault.sh missing or not executable"; exit 1
  fi

  log "  docker=$DV compose=ok disk=${DISK_GB}G ram=${RAM_MB}M tools=ok envs/$BRAND_ENV=ok"
}

# ─── Step 3: Idempotency ─────────────────────────────────────────────

idempotency_check() {
  if [[ -d "$WORKDIR" && $FORCE -eq 0 ]]; then
    err "workdir/ already exists. Re-run with --force to reinstall, or use ./update.sh to refresh."
    exit 1
  fi
  if [[ -d "$WORKDIR" && $FORCE -eq 1 ]]; then
    warn "workdir/ exists — --force given, will overwrite"
  fi
}

# ─── Step 4: Platform pin ────────────────────────────────────────────

load_platform_lock() {
  local LOCK="$SCRIPT_DIR/envs/$BRAND_ENV/platform.lock.json"
  PLATFORM_VERSION="$(jq -r '.platform_version' "$LOCK")"
  DB_REF="$(jq -r '.sources["apostol-csms/db"].ref' "$LOCK")"
  FRONTEND_REF="$(jq -r '.sources["apostol-csms/frontend"].ref' "$LOCK")"
  if [[ -z "$PLATFORM_VERSION" || "$PLATFORM_VERSION" == "null" ]]; then
    err "platform.lock.json missing 'platform_version'"; exit 1
  fi
  if [[ -z "$DB_REF" || "$DB_REF" == "null" ]]; then
    err "platform.lock.json missing 'sources.apostol-csms/db.ref'"; exit 1
  fi
  if [[ -z "$FRONTEND_REF" || "$FRONTEND_REF" == "null" ]]; then
    err "platform.lock.json missing 'sources.apostol-csms/frontend.ref'"; exit 1
  fi
  export PLATFORM_VERSION
  log "pin: platform=$PLATFORM_VERSION db=$DB_REF frontend=$FRONTEND_REF"
}

# ─── Step 5: Merge env templates → workdir/.env ──────────────────────

merge_env() {
  log "merge env: .env.template + envs/$BRAND_ENV/.env.template → workdir/.env"
  run mkdir -p "$WORKDIR"
  if [[ $DRY_RUN -eq 0 ]]; then
    cat "$SCRIPT_DIR/.env.template" > "$WORKDIR/.env"
    if [[ -f "$SCRIPT_DIR/envs/$BRAND_ENV/.env.template" ]]; then
      printf '\n# ─── env overrides (envs/%s/.env.template) ────────\n' "$BRAND_ENV" \
        >> "$WORKDIR/.env"
      cat "$SCRIPT_DIR/envs/$BRAND_ENV/.env.template" >> "$WORKDIR/.env"
    fi
    # Pin platform version into the rendered file (authoritative source).
    printf '\n# ─── pinned by install.sh from platform.lock.json ─\n' >> "$WORKDIR/.env"
    printf 'PLATFORM_VERSION=%s\n' "$PLATFORM_VERSION" >> "$WORKDIR/.env"
    chmod 600 "$WORKDIR/.env"
  fi
}

# ─── Step 6: Load secrets ────────────────────────────────────────────

load_secrets() {
  log "load secrets via envs/$BRAND_ENV/secrets/load-from-vault.sh"
  run env WORKDIR="$WORKDIR" SCRIPT_DIR="$SCRIPT_DIR" BRAND_ENV="$BRAND_ENV" \
    "$SCRIPT_DIR/envs/$BRAND_ENV/secrets/load-from-vault.sh"
  if [[ $DRY_RUN -eq 1 ]]; then return 0; fi
  [[ -s "$WORKDIR/.env" ]] || { err "workdir/.env missing or empty after secrets load"; exit 1; }
  if grep -qE '^[A-Z_][A-Z_0-9]*=("?)CHANGE_ME\1$' "$WORKDIR/.env"; then
    err "workdir/.env still contains CHANGE_ME placeholders:"
    grep -nE '^[A-Z_][A-Z_0-9]*=("?)CHANGE_ME\1$' "$WORKDIR/.env" | head -5 >&2
    err "The secrets provider did not populate every required value."
    exit 1
  fi
  chmod 600 "$WORKDIR/.env"
}

# ─── Step 7: Clone private sources ───────────────────────────────────

clone_sources() {
  log "clone platform sources at $PLATFORM_VERSION"
  # GIT_TOKEN comes from workdir/.env (populated by secrets).
  # shellcheck disable=SC1091
  [[ $DRY_RUN -eq 0 ]] && source "$WORKDIR/.env"
  if [[ -z "${GIT_TOKEN:-}" && $DRY_RUN -eq 0 ]]; then
    err "GIT_TOKEN not set in workdir/.env — secrets provider must supply it (read:repo for apostol-csms/{db,frontend})"
    exit 1
  fi

  for REPO in db frontend; do
    local TARGET="$WORKDIR/$REPO"
    local REF; if [[ "$REPO" == "db" ]]; then REF="$DB_REF"; else REF="$FRONTEND_REF"; fi
    local URL="https://${GIT_TOKEN:-TOKEN}@github.com/apostol-csms/${REPO}.git"
    if [[ -d "$TARGET/.git" ]]; then
      log "  $REPO: exists — fetch + checkout $REF"
      run git -C "$TARGET" fetch origin --tags
      run git -C "$TARGET" checkout "$REF"
      run git -C "$TARGET" submodule update --init --recursive
    else
      log "  $REPO: clone $REF"
      run git clone --recurse-submodules --branch "$REF" "$URL" "$TARGET"
    fi
  done
}

# ─── Step 8: Pull images ─────────────────────────────────────────────

pull_images() {
  log "pull platform images from ghcr.io/apostol-csms/*"
  run docker pull "ghcr.io/apostol-csms/csms-backend:$PLATFORM_VERSION"
  run docker pull "ghcr.io/apostol-csms/csms-ocpp:$PLATFORM_VERSION"
}

# ─── Step 9: Build locally ───────────────────────────────────────────

build_local() {
  log "docker compose build"
  run docker compose --env-file "$WORKDIR/.env" build
}

# ─── Step 10: First boot ─────────────────────────────────────────────

compose_cmd() { docker compose --env-file "$WORKDIR/.env" "$@"; }

wait_postgres_healthy() {
  local t=0
  until compose_cmd ps postgres --format json 2>/dev/null | jq -e '.Health == "healthy"' >/dev/null 2>&1; do
    sleep 2; t=$((t+2))
    if [[ $t -ge 120 ]]; then
      err "postgres did not reach healthy within 120s"
      compose_cmd logs --tail 40 postgres >&2
      exit 1
    fi
  done
}

first_boot() {
  log "first boot sequence"
  run compose_cmd up -d postgres
  log "  wait postgres healthy…"
  [[ $DRY_RUN -eq 0 ]] && wait_postgres_healthy
  log "  postgres healthy"

  log "  run db-init (creates users + schemas + seeds)"
  run compose_cmd up db-init
  # db-migrate has depends_on: db-init service_completed_successfully,
  # so it runs as part of `up -d` below.

  log "  bring up remaining services"
  run compose_cmd up -d
}

# ─── Step 11: Hooks ──────────────────────────────────────────────────

run_hook() {
  local NAME="$1"
  for CAND in "$SCRIPT_DIR/hooks/$NAME" "$SCRIPT_DIR/envs/$BRAND_ENV/hooks/$NAME"; do
    if [[ -x "$CAND" ]]; then
      log "hook: ${CAND#$SCRIPT_DIR/}"
      run env WORKDIR="$WORKDIR" BRAND_ENV="$BRAND_ENV" PLATFORM_VERSION="$PLATFORM_VERSION" \
        "$CAND"
    fi
  done
}

# ─── Step 12: Verify ─────────────────────────────────────────────────

record_current_env() {
  if [[ $DRY_RUN -eq 0 ]]; then
    echo "$BRAND_ENV" > "$WORKDIR/.current-env"
    echo "$PLATFORM_VERSION" > "$WORKDIR/.installed-version"
  fi
}

verify_install() {
  if [[ -x "$SCRIPT_DIR/check.sh" ]]; then
    log "verify via ./check.sh"
    if ! run "$SCRIPT_DIR/check.sh"; then
      warn "check.sh reported issues — review output above"
    fi
  else
    warn "check.sh not found — skipping verification"
  fi
}

# ─── Main ────────────────────────────────────────────────────────────

self_bootstrap "$@"

if [[ -z "$BRAND_ENV" ]]; then
  err "--env=<name> required (or BRAND_ENV env var)"
  display_help >&2
  exit 1
fi

log "Apostol CSMS install — env=$BRAND_ENV$([[ $FORCE -eq 1 ]] && echo ' [force]')$([[ $DRY_RUN -eq 1 ]] && echo ' [dry-run]')"

preflight
idempotency_check
load_platform_lock
merge_env
load_secrets
clone_sources
pull_images
run_hook pre-install.sh
build_local
first_boot
run_hook post-install.sh
record_current_env
verify_install

log "install complete — https://${DOMAIN:-<DOMAIN>}"
