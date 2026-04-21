#!/usr/bin/env bash
# envs/<env>/secrets/load-from-vault.sh — STUB
#
# Contract (called by install.sh / update.sh):
#   Inputs via env vars:
#     WORKDIR     absolute path to workdir/
#     SCRIPT_DIR  absolute path to brand-repo root
#     BRAND_ENV   "dev" | "stage" | "prod"
#
#   Behaviour:
#     - Upsert secrets into $WORKDIR/.env using upsert_var() below.
#     - Do NOT print secret values to stdout (CI may log them).
#     - After this script, no line in workdir/.env should contain
#       "CHANGE_ME" — install.sh asserts that.
#     - Exit 0 on success, non-zero on failure.
#
# Mandatory secrets (install.sh fails if any remain CHANGE_ME):
#
#   POSTGRES_PASSWORD
#   DB_PASS_{KERNEL,ADMIN,DAEMON,APIBOT,MAILBOT,OCPP,OCPI,HTTP,CPO,DRIVER}
#   OAUTH2_SECRET_{SERVICE,WEB,ANDROID,IOS,OCPP}
#   SMTP_PASSWORD_{INFO,NOREPLY,SUPPORT}
#   NUXT_SMTP_PASS
#   GIT_TOKEN                 read:repo on apostol-csms/{db,frontend}
#
# Optional (leave empty if unused):
#   STRIPE_{API_KEY,SECRET_KEY,PUBLISHABLE_KEY,WEBHOOK_SECRET}
#   YOOKASSA_{SHOP_ID,SHOP_KEY}
#   GOOGLE_{PROJECT_ID,CLIENT_ID,CLIENT_SECRET}
#   STADIA_API_KEY / GOOGLE_MAPS_API_KEY / YANDEX_MAPS_API_KEY
#
# ── Reference implementations ────────────────────────────────────────
#
# 1) Shell env (simplest — good for local dev):
#      export POSTGRES_PASSWORD=…   (set in ~/.bashrc or passed to CI)
#      upsert_var POSTGRES_PASSWORD "$POSTGRES_PASSWORD"
#
# 2) GitHub Actions (env vars already injected as secrets):
#      # Same as (1). Declare env: block in workflow to wire secrets.
#
# 3) HashiCorp Vault:
#      VAULT_ADDR=… VAULT_TOKEN=…
#      upsert_var POSTGRES_PASSWORD "$(vault kv get -field=value secret/$BRAND_ENV/pg_super)"
#      …
#
# 4) AWS Secrets Manager:
#      upsert_var POSTGRES_PASSWORD "$(aws secretsmanager get-secret-value \
#        --secret-id csms/$BRAND_ENV/pg-super --query SecretString --output text)"
#
# 5) Self-hosted plaintext file (simplest for small ops):
#      . /etc/csms/secrets.$BRAND_ENV.env
#      upsert_var POSTGRES_PASSWORD "$POSTGRES_PASSWORD"
#
# ──────────────────────────────────────────────────────────────────────

set -euo pipefail

: "${WORKDIR:?WORKDIR env var required}"
: "${BRAND_ENV:?BRAND_ENV env var required}"

upsert_var() {
  local KEY="$1" VAL="$2"
  # Quote value if it contains whitespace.
  local LINE
  if [[ "$VAL" =~ [[:space:]] ]]; then
    LINE="${KEY}=\"${VAL}\""
  else
    LINE="${KEY}=${VAL}"
  fi
  if grep -qE "^${KEY}=" "$WORKDIR/.env"; then
    # Use | as sed delim to tolerate / in values; escape & and | in VAL.
    local ESC
    ESC="$(printf '%s' "$LINE" | sed 's/[&|]/\\&/g')"
    sed -i "s|^${KEY}=.*|${ESC}|" "$WORKDIR/.env"
  else
    printf '%s\n' "$LINE" >> "$WORKDIR/.env"
  fi
}

# ─── Implementation goes here ───────────────────────────────────────
#
# DELETE THE `echo … ; exit 1` BLOCK BELOW once you have wired your
# vault. Until then, install.sh will refuse to proceed.

echo "ERROR: envs/$BRAND_ENV/secrets/load-from-vault.sh is a stub." >&2
echo "  Open this file and implement the secret-loading logic for your" >&2
echo "  environment. See the comment block at the top for the contract" >&2
echo "  and reference implementations." >&2
exit 1

# Example (uncomment and adapt):
#
# upsert_var POSTGRES_PASSWORD    "${POSTGRES_PASSWORD:-}"
# upsert_var DB_PASS_KERNEL       "${DB_PASS_KERNEL:-}"
# upsert_var DB_PASS_ADMIN        "${DB_PASS_ADMIN:-}"
# upsert_var DB_PASS_DAEMON       "${DB_PASS_DAEMON:-}"
# upsert_var DB_PASS_APIBOT       "${DB_PASS_APIBOT:-}"
# upsert_var DB_PASS_MAILBOT      "${DB_PASS_MAILBOT:-}"
# upsert_var DB_PASS_OCPP         "${DB_PASS_OCPP:-}"
# upsert_var DB_PASS_OCPI         "${DB_PASS_OCPI:-}"
# upsert_var DB_PASS_HTTP         "${DB_PASS_HTTP:-}"
# upsert_var DB_PASS_CPO          "${DB_PASS_CPO:-}"
# upsert_var DB_PASS_DRIVER       "${DB_PASS_DRIVER:-}"
# upsert_var OAUTH2_SECRET_SERVICE "${OAUTH2_SECRET_SERVICE:-}"
# upsert_var OAUTH2_SECRET_WEB     "${OAUTH2_SECRET_WEB:-}"
# upsert_var OAUTH2_SECRET_ANDROID "${OAUTH2_SECRET_ANDROID:-}"
# upsert_var OAUTH2_SECRET_IOS     "${OAUTH2_SECRET_IOS:-}"
# upsert_var OAUTH2_SECRET_OCPP    "${OAUTH2_SECRET_OCPP:-}"
# upsert_var SMTP_PASSWORD_INFO    "${SMTP_PASSWORD_INFO:-}"
# upsert_var SMTP_PASSWORD_NOREPLY "${SMTP_PASSWORD_NOREPLY:-}"
# upsert_var SMTP_PASSWORD_SUPPORT "${SMTP_PASSWORD_SUPPORT:-}"
# upsert_var NUXT_SMTP_PASS        "${NUXT_SMTP_PASS:-}"
# upsert_var GIT_TOKEN             "${GIT_TOKEN:-}"
