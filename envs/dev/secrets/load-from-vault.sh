#!/usr/bin/env bash
# envs/<env>/secrets/load-from-vault.sh — multi-provider secrets dispatcher.
#
# Populates workdir/.env with brand secrets from one of:
#   file    — ../.secrets/<env>.env             (local dev / packager)
#   env     — already-exported env vars         (CI/CD, GH Actions)
#   vault   — HashiCorp Vault KV v2             (self-hosted secret manager)
#   aws-sm  — AWS Secrets Manager               (cloud-native)
#
# Provider selection:
#   BRAND_SECRETS_PROVIDER=file|env|vault|aws-sm    (explicit)
#   or auto-detect:
#     — POSTGRES_PASSWORD + DB_PASS_KERNEL set    → env
#     — .secrets/<env>.env present                → file
#     — VAULT_ADDR + VAULT_TOKEN set              → vault
#     — AWS_REGION set                            → aws-sm
#
# Regardless of source, the same canonical key list ends up in
# workdir/.env via a single upsert loop — install.sh sees identical
# state no matter how secrets arrived.

set -euo pipefail
: "${WORKDIR:?WORKDIR env var required}"
: "${SCRIPT_DIR:?SCRIPT_DIR env var required}"
: "${BRAND_ENV:?BRAND_ENV env var required}"

PARENT_DIR="$(dirname "$SCRIPT_DIR")"

# ─── upsert helper ───────────────────────────────────────────────────

upsert_var() {
  local KEY="$1" VAL="$2"
  local LINE
  if [[ "$VAL" =~ [[:space:]] ]]; then
    LINE="${KEY}=\"${VAL}\""
  else
    LINE="${KEY}=${VAL}"
  fi
  if grep -qE "^${KEY}=" "$WORKDIR/.env"; then
    local ESC
    ESC="$(printf '%s' "$LINE" | sed 's/[&|]/\\&/g')"
    sed -i "s|^${KEY}=.*|${ESC}|" "$WORKDIR/.env"
  else
    printf '%s\n' "$LINE" >> "$WORKDIR/.env"
  fi
}

# ─── provider auto-detect ────────────────────────────────────────────

PROVIDER="${BRAND_SECRETS_PROVIDER:-}"
if [[ -z "$PROVIDER" ]]; then
  if [[ -n "${POSTGRES_PASSWORD:-}" && -n "${DB_PASS_KERNEL:-}" ]]; then
    PROVIDER="env"
  elif [[ -f "$PARENT_DIR/.secrets/$BRAND_ENV.env" ]]; then
    PROVIDER="file"
  elif [[ -n "${VAULT_ADDR:-}" && -n "${VAULT_TOKEN:-}" ]]; then
    PROVIDER="vault"
  elif [[ -n "${AWS_REGION:-}" ]] && command -v aws >/dev/null 2>&1; then
    PROVIDER="aws-sm"
  else
    echo "ERROR: no secrets source detected." >&2
    echo "  set BRAND_SECRETS_PROVIDER=<file|env|vault|aws-sm>" >&2
    echo "  or create $PARENT_DIR/.secrets/$BRAND_ENV.env (chmod 600)" >&2
    exit 1
  fi
fi

echo "[load-secrets] provider=$PROVIDER env=$BRAND_ENV"

# ─── provider implementations ────────────────────────────────────────

case "$PROVIDER" in
  file)
    SECRETS_FILE="$PARENT_DIR/.secrets/$BRAND_ENV.env"
    [[ -f "$SECRETS_FILE" ]] || { echo "ERROR: $SECRETS_FILE not found" >&2; exit 1; }
    PERMS="$(stat -c '%a' "$SECRETS_FILE")"
    if [[ "$PERMS" != "600" && "$PERMS" != "400" ]]; then
      echo "ERROR: $SECRETS_FILE permissions are $PERMS — must be 600 or 400" >&2
      echo "Fix: chmod 600 $SECRETS_FILE" >&2
      exit 1
    fi
    set -a
    # shellcheck disable=SC1090
    source "$SECRETS_FILE"
    set +a
    ;;

  env)
    # Nothing to source — caller already exported secrets into the env.
    # Typical CI pattern: GitHub Actions workflow forwards `secrets.*`
    # as env vars on the runner, which arrive here as already-set
    # shell variables. No file on disk, no vault round-trip.
    :
    ;;

  vault)
    # HashiCorp Vault KV v2 — namespace convention: secret/<env>/<key>.
    # Customise per-brand Vault layout; the defaults below assume one
    # secret per key, stored with field name "value".
    : "${VAULT_ADDR:?VAULT_ADDR required for vault provider}"
    : "${VAULT_TOKEN:?VAULT_TOKEN required for vault provider}"
    vget() { vault kv get -field=value "secret/$BRAND_ENV/$1" 2>/dev/null || true; }
    export POSTGRES_PASSWORD="$(vget pg_super)"
    export DB_PASS_KERNEL="$(vget db_kernel)"
    export DB_PASS_ADMIN="$(vget db_admin)"
    export DB_PASS_DAEMON="$(vget db_daemon)"
    export DB_PASS_APIBOT="$(vget db_apibot)"
    export DB_PASS_MAILBOT="$(vget db_mailbot)"
    export DB_PASS_OCPP="$(vget db_ocpp)"
    export DB_PASS_OCPI="$(vget db_ocpi)"
    export DB_PASS_HTTP="$(vget db_http)"
    export DB_PASS_CPO="$(vget db_cpo)"
    export DB_PASS_DRIVER="$(vget db_driver)"
    export OAUTH2_SECRET_SERVICE="$(vget oauth2_service)"
    export OAUTH2_SECRET_WEB="$(vget oauth2_web)"
    export OAUTH2_SECRET_ANDROID="$(vget oauth2_android)"
    export OAUTH2_SECRET_IOS="$(vget oauth2_ios)"
    export OAUTH2_SECRET_OCPP="$(vget oauth2_ocpp)"
    export SMTP_PASSWORD_INFO="$(vget smtp_info)"
    export SMTP_PASSWORD_NOREPLY="$(vget smtp_noreply)"
    export SMTP_PASSWORD_SUPPORT="$(vget smtp_support)"
    export NUXT_SMTP_PASS="$(vget nuxt_smtp)"
    export GIT_TOKEN="$(vget git_token)"
    # Optional:
    export STRIPE_API_KEY="$(vget stripe_api_key)"
    export STRIPE_SECRET_KEY="$(vget stripe_secret_key)"
    export STRIPE_WEBHOOK_SECRET="$(vget stripe_webhook_secret)"
    export STADIA_API_KEY="$(vget stadia_api_key)"
    export GOOGLE_CLIENT_SECRET="$(vget google_client_secret)"
    ;;

  aws-sm)
    # AWS Secrets Manager — naming convention: csms/<env>/<key>.
    # Stored as SecretString (single value, no JSON). Customise per brand.
    : "${AWS_REGION:?AWS_REGION required for aws-sm provider}"
    smget() { aws secretsmanager get-secret-value --secret-id "csms/$BRAND_ENV/$1" --query SecretString --output text 2>/dev/null || true; }
    export POSTGRES_PASSWORD="$(smget pg-super)"
    export DB_PASS_KERNEL="$(smget db-kernel)"
    export DB_PASS_ADMIN="$(smget db-admin)"
    export DB_PASS_DAEMON="$(smget db-daemon)"
    export DB_PASS_APIBOT="$(smget db-apibot)"
    export DB_PASS_MAILBOT="$(smget db-mailbot)"
    export DB_PASS_OCPP="$(smget db-ocpp)"
    export DB_PASS_OCPI="$(smget db-ocpi)"
    export DB_PASS_HTTP="$(smget db-http)"
    export DB_PASS_CPO="$(smget db-cpo)"
    export DB_PASS_DRIVER="$(smget db-driver)"
    export OAUTH2_SECRET_SERVICE="$(smget oauth2-service)"
    export OAUTH2_SECRET_WEB="$(smget oauth2-web)"
    export OAUTH2_SECRET_ANDROID="$(smget oauth2-android)"
    export OAUTH2_SECRET_IOS="$(smget oauth2-ios)"
    export OAUTH2_SECRET_OCPP="$(smget oauth2-ocpp)"
    export SMTP_PASSWORD_INFO="$(smget smtp-info)"
    export SMTP_PASSWORD_NOREPLY="$(smget smtp-noreply)"
    export SMTP_PASSWORD_SUPPORT="$(smget smtp-support)"
    export NUXT_SMTP_PASS="$(smget nuxt-smtp)"
    export GIT_TOKEN="$(smget git-token)"
    # Optional:
    export STRIPE_API_KEY="$(smget stripe-api-key)"
    export STRIPE_SECRET_KEY="$(smget stripe-secret-key)"
    export STRIPE_WEBHOOK_SECRET="$(smget stripe-webhook-secret)"
    export STADIA_API_KEY="$(smget stadia-api-key)"
    export GOOGLE_CLIENT_SECRET="$(smget google-client-secret)"
    ;;

  *)
    echo "ERROR: unknown BRAND_SECRETS_PROVIDER=$PROVIDER" >&2
    exit 1
    ;;
esac

# ─── GIT_TOKEN fallback to `gh auth token` ───────────────────────────
# Useful when a developer on a local machine has `gh auth login` with
# read:repo — no need to duplicate the PAT into .secrets/<env>.env.
# CI / vault / aws-sm providers should pass GIT_TOKEN explicitly.

if [[ -z "${GIT_TOKEN:-}" ]]; then
  if command -v gh >/dev/null 2>&1 && gh auth token >/dev/null 2>&1; then
    GIT_TOKEN="$(gh auth token)"
    echo "[load-secrets] GIT_TOKEN filled from 'gh auth token'"
  fi
fi

# ─── Canonical key list — upsert into workdir/.env ───────────────────
# All providers converge here. install.sh later asserts no CHANGE_ME
# survives in workdir/.env.

MANDATORY=(
  POSTGRES_PASSWORD
  DB_PASS_KERNEL DB_PASS_ADMIN DB_PASS_DAEMON DB_PASS_APIBOT DB_PASS_MAILBOT
  DB_PASS_OCPP DB_PASS_OCPI DB_PASS_HTTP DB_PASS_CPO DB_PASS_DRIVER
  OAUTH2_SECRET_SERVICE OAUTH2_SECRET_WEB OAUTH2_SECRET_ANDROID
  OAUTH2_SECRET_IOS OAUTH2_SECRET_OCPP
  SMTP_PASSWORD_INFO SMTP_PASSWORD_NOREPLY SMTP_PASSWORD_SUPPORT NUXT_SMTP_PASS
)

OPTIONAL=(
  # GIT_TOKEN was once mandatory for cloning the apostol-csms platform
  # repos (db, frontend, backend). Those are public now, so anonymous
  # `git clone` works. The token is still respected — if set, it is
  # injected into clone URLs — but absence is no longer a blocker.
  # Kept here so brand vaults that historically supplied it round-trip
  # cleanly without warnings.
  GIT_TOKEN
  GOOGLE_CLIENT_ID GOOGLE_CLIENT_SECRET
  STRIPE_API_KEY STRIPE_SECRET_KEY STRIPE_PUBLISHABLE_KEY STRIPE_WEBHOOK_SECRET
  YOOKASSA_SHOP_KEY YOOKASSA_OAUTH_CLIENT_SECRET
  STADIA_API_KEY GOOGLE_MAPS_API_KEY YANDEX_MAPS_API_KEY
  # AI support agent — only consumed when the `ai` compose profile is on.
  # Which of these matters depends on LLM_PROVIDER; the rest stay empty.
  LLM_PROVIDER
  OPENAI_API_KEY ANTHROPIC_API_KEY
  YANDEX_API_KEY YANDEX_FOLDER_ID GIGACHAT_API_KEY
  BRAND_GIT_TOKEN
  CURRENT_KEY
  AUTH_WEBAPP_PRIMARY AUTH_WEBAPP_CHANNELS AUTH_DRIVER_PRIMARY AUTH_DRIVER_CHANNELS
)

for KEY in "${MANDATORY[@]}"; do
  VAL="${!KEY:-}"
  if [[ -z "$VAL" ]]; then
    echo "ERROR: mandatory secret $KEY is empty (provider=$PROVIDER)" >&2
    exit 1
  fi
  upsert_var "$KEY" "$VAL"
done

for KEY in "${OPTIONAL[@]}"; do
  VAL="${!KEY:-}"
  [[ -n "$VAL" ]] && upsert_var "$KEY" "$VAL"
done

# Manifest-seed prefix propagation. Beyond the named OPTIONAL list, any
# shell-env variable matching these prefixes is upserted into workdir/.env
# — typical providers (.secrets/<env>.env, vault, AWS Secrets Manager)
# carry operator-managed manifest-seed config (theme tokens, auth channels,
# map provider keys, project deployment defaults, company legal extras)
# that the named OPTIONAL list intentionally leaves out to stay short.
# Empty values are dropped (mirrors OPTIONAL handling). compgen -v <prefix>
# is bash-native and only returns set variables.
# REGISTRY_ carries the credentials of a private image registry (a brand
# mirroring the platform images into its own). install.sh/update.sh run
# `docker login` with them before `compose pull`; absent = public registry,
# login skipped. They must not sit in a committed .env.template.
#
# AI_ joins the list so every AI_* knob round-trips from the vault —
# AI_SERVICE_KEY and AI_HTTP_PROXY carry credentials and must not sit in
# a committed .env.template, and the remaining AI_* values are per-env
# tuning an operator may want to override without a commit.
for PREFIX in BRANDING_ AUTH_ MAP_ PROJECT_ COMPANY_ AI_ REGISTRY_; do
  for KEY in $(compgen -v "$PREFIX"); do
    VAL="${!KEY:-}"
    [[ -n "$VAL" ]] && upsert_var "$KEY" "$VAL"
  done
done

chmod 600 "$WORKDIR/.env"
echo "[load-secrets] done"
