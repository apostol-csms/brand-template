# Apostol CSMS — brand-template

Template repository for deploying a new Apostol CSMS brand. One command creates a brand-specific repo pre-wired with `install.sh`, `update.sh`, `check.sh`, a multi-env structure, and the reference `docker-compose.yaml`.

```
Platform side              │  Brand side (your deployment)
───────────────────────────┼─────────────────────────────────────────
apostol-csms/backend       │  <brand>/csms          ← this template
apostol-csms/db            │  ├── docker-compose.yaml
apostol-csms/frontend      │  ├── .env.template
apostol-csms/cs            │  ├── install.sh / update.sh / check.sh
↓                          │  ├── envs/{dev,stage,prod}/
ghcr.io/apostol-csms/      │  │   ├── platform.lock.json
  ├── csms-backend (public)│  │   └── secrets/load-from-vault.sh
  └── csms-ocpp    (public)│  └── hooks/{pre,post}-{install,update}.sh
```

**Philosophy:** platform publishes public Docker images and private source repos. Brand owns the deployment — `docker-compose.yaml`, secrets, hooks, version pinning — and never automatically rebuilds when platform ships a new version.

## Quick start

```bash
# 1. Create a brand repo from this template (GitHub CLI).
gh repo create <brand>/csms --template apostol-csms/brand-template --private --clone
cd csms

# 2. Edit the per-env overrides. Replace example.com with your domain.
$EDITOR envs/prod/.env.template
$EDITOR envs/prod/platform.lock.json   # bump PLATFORM_VERSION + digests

# 3. Put the secrets where the loader will find them. The shipped
#    envs/<env>/secrets/load-from-vault.sh is a working multi-provider
#    dispatcher (file / env / vault / aws-sm), not a stub — for the
#    simplest case just create ../.secrets/prod.env.
$EDITOR ../.secrets/prod.env

# 4. Stage the license and issue TLS (see "TLS certificates" below —
#    ELEVEN separate certificates, not one multi-SAN).
cp <issued>.license.json ../.secrets/license.json

# 5. Deploy.
./install.sh --env=prod
./check.sh
```

### TLS certificates — eleven lineages, not one

`default.conf.template` points every `server` block at its **own**
certificate directory (`/etc/letsencrypt/live/cloud.${DOMAIN}/`,
`/live/api.${DOMAIN}/`, …). A single `certbot certonly` with a long list
of `-d` produces **one** lineage named after the first `-d`, and nginx
then fails to start on the other ten. Issue them one per name; the apex
takes `www` along with it:

```bash
D=<your-domain>; EMAIL=<a mailbox you actually read>
certbot certonly --standalone --non-interactive --agree-tos --email "$EMAIL" \
  --cert-name "$D" -d "$D" -d "www.$D"
for s in cloud cpo cs admin driver pay auth api ws ocpp; do
  certbot certonly --standalone --non-interactive --agree-tos --email "$EMAIL" \
    --cert-name "$s.$D" -d "$s.$D"
done
cp -a /etc/letsencrypt <workspace>/.secrets/letsencrypt   # hooks/pre-install.sh picks it up
```

All eleven names must resolve to the host **before** certbot runs — there
is no wildcard in the shipped config, and `hooks/pre-install.sh` bakes the
tree into the nginx image at build time.

Renewal is the nginx container's job (`certbot renew --webroot`, twice a
day, with `nginx -s reload` as deploy-hook). **Disable the host's own
`certbot.timer`** — issuing above leaves it enabled, and once the stack
holds :80 a host-side standalone renewal fails silently every twelve
hours until the certificate expires.

### Pulling from a private registry

Defaults are the public contour: platform images from GHCR, base images
from Docker Hub. A brand mirroring images into its own registry sets four
variables in `envs/<env>/.env.template` — `REGISTRY`, `BASE_REGISTRY`,
`PGBOUNCER_IMAGE`, `PGWEB_IMAGE` (see `[R-0]` in `.env.template`) — and
puts `REGISTRY_USER` / `REGISTRY_PASS` in `.secrets/<env>.env`.
`install.sh` and `update.sh` then run `docker login` before `compose
pull`; with the variables absent the step is skipped and nothing changes.

Verify the switch before deploying — this must print `0`:

```bash
docker compose --env-file workdir/.env config | grep -cE 'ghcr\.io|docker\.io'
```

One-liner for a fresh server (clones the repo, re-execs itself):

```bash
curl -fsSL https://raw.githubusercontent.com/<brand>/csms/main/install.sh | \
  BRAND_ENV=prod \
  BRAND_REPO_URL=https://github.com/<brand>/csms \
  bash
```

## Repository layout

```
<brand>/csms/
├── README.md                         Operator guide (this file, customise it)
├── .gitignore                        Keeps workdir/, .secrets/, conf/ out of git
├── docker-compose.yaml               14 services, image-based
├── .env.template                     Root defaults, incl. [R-0] registry block
├── install.sh                        First-time deployment
├── update.sh                         Version bump + rolling restart
├── check.sh                          Health verification
├── docker-*.sh                       up / down / logs / build helpers
│
├── .docker/                          Locally-built infra images
│   ├── nginx-certbot/                Reverse proxy + TLS renewal loop
│   │   ├── default.conf.template     Per-subdomain server blocks (envsubst $DOMAIN)
│   │   ├── nginx.conf                resolver + $*_upstream maps
│   │   └── entrypoint.sh             render config → certbot renew loop
│   ├── pgbouncer/  pgweb/            Built; ARG-parameterised base image
│   └── auth/ db-migrate/ postgres/ test-run/ wireguard/
│                                     Not built by this compose — kept as the
│                                     shared canonical home (postgres/postgresql.conf
│                                     is referenced from compose as the tuning baseline)
│
├── envs/
│   ├── dev/
│   │   ├── .env.template             Overrides root (DOMAIN=localhost, …)
│   │   ├── platform.lock.json        Pinned PLATFORM_VERSION + refs
│   │   ├── render.sh                 Renders envs/templates/** into workdir/
│   │   ├── secrets/
│   │   │   └── load-from-vault.sh    Writes secrets into workdir/.env
│   │   └── hooks/
│   │       └── (per-env pre/post-install/update.sh, if any)
│   ├── stage/  (same structure)
│   ├── prod/   (same structure)
│   └── templates/                    Sources for render.sh — app .env files
│       ├── backend/db/sql/*.psql.template
│       ├── frontend/{webapp,driver,pay}/
│       └── landing/
│
├── hooks/                            Global (all envs)
│   ├── pre-install.sh
│   ├── post-install.sh
│   ├── pre-update.sh
│   └── post-update.sh
│
├── conf/                             Gitignored — staged by hooks/pre-install.sh
│                                     from .secrets/ (license.json, landing.env)
│
└── workdir/                          Gitignored — created by install.sh
    ├── .env                          Merged env (root + per-env + secrets)
    ├── .current-env                  "prod" (used by update.sh)
    ├── .installed-version            Current PLATFORM_VERSION
    ├── .installed-version.prev       For --rollback
    ├── db/                           Clone of apostol-csms/db @ pinned tag
    └── frontend/                     Clone of apostol-csms/frontend @ tag
```

## Workflow

### install.sh — first-time deployment

Runs the full pipeline end-to-end on a fresh server:

1. **Self-bootstrap** — if run via pipe, `git clone` into `/opt/<brand>/` and re-exec.
2. **Pre-flight** — Docker ≥24, compose v2, disk ≥20 GB, RAM ≥4 GB, required tools (`git jq envsubst curl`).
3. **Idempotency** — refuses if `workdir/` already exists (unless `--force`).
4. **Platform pin** — reads `envs/<env>/platform.lock.json` → `PLATFORM_VERSION` + git refs for db/frontend.
5. **Merge env** — `.env.template` + `envs/<env>/.env.template` → `workdir/.env`, chmod 600.
6. **Load secrets** — calls `envs/<env>/secrets/load-from-vault.sh`; asserts no `CHANGE_ME` remain.
7. **Clone sources** — `git clone --recurse-submodules apostol-csms/{db,frontend}@<ref>` → `workdir/`.
8. **Pull images** — `csms-backend` + `csms-ocpp` from GHCR (public — no auth needed).
9. **Pre-install hook** — `hooks/pre-install.sh` + `envs/<env>/hooks/pre-install.sh`.
10. **Build local** — `docker compose build` (db-init, frontend apps, infra).
11. **First boot** — `postgres` → wait healthy → `db-init` (run to completion) → `up -d` for the rest (db-migrate is chained via `depends_on: service_completed_successfully`).
12. **Post-install hook**.
13. **Record state** — writes `workdir/.current-env` + `workdir/.installed-version`.
14. **Verify** — runs `./check.sh` (warn-only; does not fail install).

Flags: `--env=<name>` (required), `--force`, `--dry-run`.

### update.sh — version bump

Symmetric to install.sh but for existing deployments:

1. `git pull` the brand-repo (ff-only).
2. **Resolve target version**: `envs/<env>/platform.lock.json` (default), `--platform=<ver>` (override), or `--rollback` (reads `workdir/.installed-version.prev`).
3. `--diff-compose` (standalone): curl the reference `docker-compose.yaml` from the platform release and `diff -u` against local.
4. Reload secrets (may have rotated).
5. `docker pull` new images.
6. `git fetch` + `git checkout` new refs in `workdir/{db,frontend}`.
7. Pre-update hook.
8. `docker compose build` (locally-built images). `--frontend-only` narrows to webapp/driver/pay/landing.
9. **`docker compose run --rm db-migrate`** — blocking gate. On failure, exits 2 and **leaves the stack on the previous version**. Operator investigates, fixes, re-runs.
10. Rolling restart — `up -d --no-deps --force-recreate <services>`.
11. Post-update hook.
12. Record `.installed-version.prev` ← old, `.installed-version` ← new.
13. `./check.sh` (fails update on exit 2).
14. `docker image prune -f`.

Flags: `--platform=<ver>`, `--frontend-only`, `--diff-compose`, `--rollback`, `--dry-run`.

### check.sh — health verification

Runs 10 checks:

| Check | Pass criterion |
|-------|----------------|
| `containers` | All compose services `running` + `healthy` |
| `postgres` | `pg_isready` from inside the container |
| `api` | `GET https://${DOMAIN}/api/v1/ping` → 200 |
| `openid` | `GET https://auth.${DOMAIN}/.well-known/openid-configuration` → 200 |
| `ocpp` | TCP `:9220` reachable |
| `frontend` | `GET https://${DOMAIN}/` → 200/301/302 |
| `tls` | Minimum expiry across sample subdomains ≥ 7 days |
| `disk` | Partition < 85% (warn) / 90% (fail) |
| `memory` | MemAvailable ≥ 1 GB |
| `version` | Running backend image tag matches `workdir/.installed-version` |

Exit codes: **0** = all green, **1** = ≥1 warn, **2** = ≥1 fail. `--json` emits a one-line JSON payload for Datadog/Prometheus.

When `DOMAIN=localhost`, HTTPS / TLS checks degrade to `warn` instead of `fail`.

## Secrets setup

`install.sh` / `update.sh` delegate the entire secrets problem to `envs/<env>/secrets/load-from-vault.sh`. The stub documents **5 reference implementations**:

### 1. Shell env (simplest — local dev)

```bash
# Pre-export secrets in your shell, then:
upsert_var POSTGRES_PASSWORD "$POSTGRES_PASSWORD"
upsert_var DB_PASS_KERNEL   "$DB_PASS_KERNEL"
…
```

### 2. GitHub Actions

Same as shell env — declare secrets in the workflow `env:` block, they appear as env vars, the script upserts them.

### 3. HashiCorp Vault

```bash
: "${VAULT_ADDR:?}"  "${VAULT_TOKEN:?}"
upsert_var POSTGRES_PASSWORD "$(vault kv get -field=value secret/$BRAND_ENV/pg_super)"
upsert_var DB_PASS_KERNEL    "$(vault kv get -field=value secret/$BRAND_ENV/kernel)"
…
```

### 4. AWS Secrets Manager

```bash
get() {
  aws secretsmanager get-secret-value \
    --secret-id "csms/$BRAND_ENV/$1" --query SecretString --output text
}
upsert_var POSTGRES_PASSWORD "$(get pg-super)"
…
```

### 5. Self-hosted plaintext file

```bash
# /etc/csms/secrets.<env>.env — chmod 600, owned by the deploy user
. /etc/csms/secrets.$BRAND_ENV.env
upsert_var POSTGRES_PASSWORD "$POSTGRES_PASSWORD"
…
```

**Mandatory secrets** (install refuses to start if any `CHANGE_ME` survive):

```
POSTGRES_PASSWORD
DB_PASS_{KERNEL,ADMIN,DAEMON,APIBOT,MAILBOT,OCPP,OCPI,HTTP,CPO,DRIVER}
OAUTH2_SECRET_{SERVICE,WEB,ANDROID,IOS,OCPP}
SMTP_PASSWORD_{INFO,NOREPLY,SUPPORT}
NUXT_SMTP_PASS
GIT_TOKEN                    # read:repo on apostol-csms/{db,frontend}
```

**Optional** (leave empty if feature unused): Stripe, YooKassa, Google OAuth, map API keys.

## Per-env customisation

### Version drift between envs

Each env pins its own `PLATFORM_VERSION` in `envs/<env>/platform.lock.json`. Typical pattern:

```
dev     1.5.0-rc2     (aggressive — try next release)
stage   1.4.0-rc1     (stabilising — 1-2 weeks behind dev)
prod    1.3.7         (conservative — only stable)
```

Bump one env at a time, commit the lock.json change, run `./update.sh --env=<env>` on that host.

### Compose overrides

Drop `docker-compose.override.yaml` at repo root (global) or `envs/<env>/docker-compose.override.yaml` (per-env — not automatically picked up by default, see below) to add/modify services without touching the base `docker-compose.yaml`.

```yaml
# envs/dev/docker-compose.override.yaml — hot-reload for dev
services:
  backend:
    volumes:
      - ./workdir/backend-dev:/opt/csms
    environment:
      LOG_LEVEL: debug
```

To use a per-env override, set `COMPOSE_FILE` before install/update:

```bash
export COMPOSE_FILE="docker-compose.yaml:envs/$BRAND_ENV/docker-compose.override.yaml"
./update.sh
```

### Hook specialisation

`install.sh` and `update.sh` call **both** `hooks/<name>` AND `envs/<env>/hooks/<name>` (if the per-env file exists). Use the per-env layer for things that only apply to one environment:

```
envs/prod/hooks/pre-update.sh    # only prod: snapshot pg volume before update
envs/dev/hooks/post-install.sh   # only dev: seed test drivers + connectors
```

## Upgrading the platform

1. Watch the [apostol-csms/backend releases](https://github.com/apostol-csms/backend/releases) for new tags. Each release ships with:
   - `docker-compose.reference.yaml` — authoritative compose, for diff
   - `.env.template` — any new variables introduced
   - `platform.lock.json` — ready-to-drop pin file
   - `MIGRATION.md` — required for minor/major bumps (patch-only bumps are automatic)

2. Read `MIGRATION.md` for breaking changes.

3. Bump `envs/<env>/platform.lock.json` to the new version + commit digests:

   ```bash
   # The release workflow publishes a ready lock file as an asset.
   curl -fsSL https://github.com/apostol-csms/backend/releases/download/v1.3.8/platform.lock.json \
     > envs/stage/platform.lock.json
   git add envs/stage/platform.lock.json
   git commit -m "chore: bump stage to v1.3.8"
   ```

4. Diff the reference compose against yours — reconcile new vars/services:

   ```bash
   ./update.sh --diff-compose
   ```

5. Update:

   ```bash
   ./update.sh          # uses workdir/.current-env
   ./check.sh
   ```

6. On rollback: `./update.sh --rollback` restores the previous pin (via `workdir/.installed-version.prev`). Note that database migrations don't automatically reverse — you may need `pg_restore` from a pre-update snapshot (the pre-update hook should capture this).

### Semver semantics

| Bump | Meaning | Action |
|------|---------|--------|
| **Patch** (1.3.6 → 1.3.7) | Bugfix in SQL/C++, DB patches compatible, no env/compose changes | `./update.sh` |
| **Minor** (1.3.7 → 1.4.0) | New features / endpoints / possibly new env vars / new compose service | Read `MIGRATION.md`, apply env+compose deltas |
| **Major** (1.x → 2.0.0) | Breaking DB migration, renamed envs | Backup → careful read → possibly manual steps |

Pre-release tags (`vX.Y.Z-alpha`, `-rc1`, `-beta`) are **not** tagged `:latest` on GHCR and **are** flagged Prerelease on GitHub Releases.

## Troubleshooting

### `install.sh` fails at "load secrets"

```
[install] ERROR: envs/dev/secrets/load-from-vault.sh is a stub.
```

The stub must be replaced with real logic — see "Secrets setup" above. It cannot succeed until you open the file and implement the secret-loading path for your vault of choice.

### `install.sh` fails with `CHANGE_ME`

```
[install] ERROR: workdir/.env still contains CHANGE_ME placeholders:
workdir/.env:42:POSTGRES_PASSWORD=CHANGE_ME
```

Your secrets loader didn't populate every mandatory variable. Check the `upsert_var` calls in `envs/<env>/secrets/load-from-vault.sh` against the mandatory-list above.

### `check.sh` reports `api: fail` but the service is up

Likely DNS not pointing at this host, or TLS cert not yet issued. Check:

```bash
dig +short A cloud.<domain>
curl -v https://cloud.<domain>/api/v1/ping
```

Fix DNS + certbot, then re-run `check.sh`.

### `db-migrate` fails during `update.sh`

```
[update] ERROR: db-migrate FAILED. The stack is still on the previous version.
```

Stack is **intact** at the previous version. Investigate:

```bash
docker compose --env-file workdir/.env logs db-migrate
# ... identify the failing patch ...
docker compose --env-file workdir/.env run --rm db-migrate --status
```

If the failure is in a platform patch, file an issue at `apostol-csms/db`. If it's your brand's custom patch, fix and re-run `update.sh`.

### `workdir/` inconsistent after aborted install

```bash
# Start over cleanly.
docker compose --env-file workdir/.env down -v
rm -rf workdir/
./install.sh --env=<env>
```

## Links

| Resource | URL |
|----------|-----|
| Platform backend (C++) | [apostol-csms/backend](https://github.com/apostol-csms/backend) |
| Platform DB (PL/pgSQL) | [apostol-csms/db](https://github.com/apostol-csms/db) |
| Platform frontend (Next.js / Vite / Nuxt) | [apostol-csms/frontend](https://github.com/apostol-csms/frontend) |
| OCPP Central System (C++) | [apostol-csms/cs](https://github.com/apostol-csms/cs) |
| libapostol (C++20 framework) | [apostoldevel/libapostol](https://github.com/apostoldevel/libapostol) |
| db-platform (PL/pgSQL framework) | [apostoldevel/db-platform](https://github.com/apostoldevel/db-platform) |

## License

This template itself is MIT-licensed. Platform components carry their own licenses (see each repo). Brand-specific content in `<brand>/csms` is owned by the brand.
