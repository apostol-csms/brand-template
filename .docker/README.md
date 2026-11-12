# brand-template/.docker/ — locally-built infra images

This directory holds the Dockerfiles + entrypoints + configs for the
**locally-built** infra services that complement the GHCR-pulled
platform images (`csms-{backend,ocpp,db,webapp,driver,pay,auth,ai-service,platform-service}`).

The platform itself ships as GHCR images. Everything here is brand-side
infrastructure: TLS termination, DB connection pooling, DB admin UI,
message catch-all, run-time helpers, optional VPN.

## What's inside

| Subdir | Purpose | Built into |
|---|---|---|
| `auth/` | Stub `auth` placeholder (legacy slot) | `local/<brand>-auth` |
| `db-migrate/` | Stub for the `db-migrate` compose service | `local/<brand>-db-migrate` |
| `pgbouncer/` | Postgres connection pool (session pooling) | `local/<brand>-pgbouncer` |
| `postgres/` | `postgresql.conf` baseline (pgtune-style), kept for reference | not built: compose runs the stock `postgres:18` image |
| `libpq/` | `pg_service.conf` mounted into the backend | not built |
| `test-run/` | Test harness container | `local/<brand>-test-run` |
| `wireguard/` | Optional admin VPN (compose profile `vpn`) | `local/<brand>-wireguard` |
| `nginx-certbot/` | TLS-terminating reverse proxy + Let's Encrypt webroot renewal | `local/<brand>-nginx` |

## Notes per directory

- **`postgres/`** — compose does not build this directory: it runs the
  stock `postgres:18` image and passes every tunable as a `-c` flag from
  the `PG_*` variables of `workdir/.env`. `postgresql.conf` here is only
  the reference baseline; editing it changes nothing at runtime.
- **`pgbouncer/`** — `userlist.txt` in the template is a placeholder; the
  entrypoint writes the real one at start (one line: the auth role and
  its password from `DB_PASS_PGBOUNCER`). Never commit a generated
  `userlist.txt`.
- **`wireguard/`** — `Dockerfile`, `wg0.conf`, `postup.sh`, `postdown.sh`,
  `keys-init.sh` and `.gitignore` only. `server/{privatekey,publickey}` and
  `peers/*/{privatekey,publickey}` are deliberately **excluded** —
  generate them with `./keys-init.sh` at deploy time. `.gitignore`
  ensures nothing leaks if you accidentally `git add .` later.
- **`nginx-certbot/`** — `frontend/docs/` (the Swagger UI served at
  `/docs/`) and `.gitignore` live here; so do `Dockerfile`, `nginx.conf`,
  `default.conf.template`, `includes/`, `entrypoint.sh`, `tls-rsa.sh` and
  `renew-status.sh`. A brand with
  extra domains adds its own server blocks on top. `frontend/docs/README.md`
  explains how `api.yaml` is generated per brand.

## Overlay pattern (how live brands customise)

There is no inheritance / submodule mechanism. Each brand repository
(`brands/<brand>/csms/`) keeps its **own full copy** of `.docker/`, and
platform-level changes are applied by syncing every copy:

```
1. Edit brand-template/.docker/<sub>/<file>
2. cp -r brand-template/.docker/<sub>/ → each brand's csms/.docker/<sub>/
3. Commit + push the template and every brand repository in lockstep
```

For new brands provisioned from this template via `gh repo create
--template`, `.docker/` arrives pre-populated and ready — no extra
work beyond the standard install.sh flow.
