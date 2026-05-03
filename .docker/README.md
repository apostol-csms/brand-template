# brand-template/.docker/ — locally-built infra images

This directory holds the Dockerfiles + entrypoints + configs for the
**locally-built** infra services that complement the GHCR-pulled
platform images (`csms-{backend,ocpp,db,webapp,driver,pay,auth}`).

After Phase 10 (2026-04-25) the platform itself ships as 7 GHCR images.
Everything here is brand-side infrastructure: TLS termination, DB
connection pooling, DB admin UI, message catch-all, run-time helpers,
optional VPN.

## What's inside

| Subdir | Purpose | Built into | State across the 3 live brands |
|---|---|---|---|
| `auth/` | Stub `auth` placeholder (legacy slot) | `local/<brand>-auth` | identical |
| `db-migrate/` | Stub for the `db-migrate` compose service | `local/<brand>-db-migrate` | identical |
| `pgbouncer/` | Postgres connection pool with SCRAM regen | `local/<brand>-pgbouncer` | identical except chargemecar (older entrypoint, leaked SCRAM hashes — security finding #16) |
| `pgweb/` | Web UI for postgres | `local/<brand>-pgweb` | identical |
| `postgres/` | Vanilla `postgres:18` + tuned `postgresql.conf` | extends `postgres:18` | `.env` differs (chargemecar=scram, ocpp-css=md5); `postgresql.conf` is host-tuned |
| `test-run/` | Test harness container | `local/<brand>-test-run` | identical |
| `wireguard/` | Optional admin VPN (compose profile `vpn`) | `local/<brand>-wireguard` | chargemecar/ocpp-css leak private keys (security finding #17); plugme is clean |
| `nginx-certbot/` | TLS-terminating reverse proxy + Let's Encrypt webroot renewal | `local/<brand>-nginx` | **all 3 different** — biggest divergence; tracked as standalone debt #15 (not migrated to brand-template yet) |

## Provenance

The 4 trivially-shared directories (`auth`, `db-migrate`, `pgweb`,
`test-run`) are byte-identical to the live brand-repo copies and were
copied straight from `ocpp-css/csms/.docker/<sub>/` on 2026-05-04.

The 3 partially-divergent directories (`pgbouncer`, `postgres`,
`wireguard`) take ocpp-css as the **canonical baseline**, with
post-copy fixes:

- **`postgres/.env`** — `POSTGRES_INITDB_ARGS` set to
  `--auth=scram-sha-256 --auth-local=trust` (ocpp-css used the older
  md5; scram-sha-256 matches what postgres 14+ creates roles with by
  default and what pgbouncer regenerates against).
- **`wireguard/`** — `Dockerfile` + `wg0.conf` + `postup.sh` +
  `postdown.sh` only. `server/{privatekey,publickey}` and
  `peers/*/{privatekey,publickey}` deliberately **excluded** —
  generate them with `./keys-init.sh` at deploy time. `.gitignore`
  ensures nothing leaks if you accidentally `git add .` later.

## Overlay pattern (how live brands customise)

There is no inheritance / submodule mechanism right now. Each live
brand-repo (`brands/<brand>/csms/`) keeps its **own full copy** of
`.docker/`, and platform-level changes are applied by 4-place sync:

```
1. Edit brand-template/.docker/<sub>/<file>
2. cp -r brand-template/.docker/<sub>/ → brands/chargemecar/csms/.docker/<sub>/
3. ... ditto for ocpp-css/csms and apostol-csms/plugme/csms
4. Commit + push all 4 repos in lockstep
```

This is documented in the operator memory note "Brand-template/brand-repo
4-place sync". Future improvement direction (see
[`zero-build-architecture.md`](../../docs/operations/zero-build-architecture.md)
tech debt #15): consume the template via git-subtree pull or a
top-level sync script, but the current 4-place rule is the contract.

For new brands provisioned from this template via `gh repo create
--template`, `.docker/` arrives pre-populated and ready — no extra
work beyond the standard install.sh flow.

## What still lives only in live brand-repos (not migrated)

- **`nginx-certbot/`** — varies sharply per-brand (chargemecar 38 files,
  ocpp-css/plugme 162 files due to embedded swagger UI, oauth assets,
  per-brand server-blocks for `${ALT_DOMAIN}` / `apostoldevel.{com,ru}`).
  Migration requires structural decomposition (base template +
  brand-extensible `extra-domains.conf.d/` slot), tracked as
  zero-build doc tech debt #15.

## Security findings — separate cleanup tickets

Audit on 2026-05-04 surfaced two leaks-in-git that are independent of
this consolidation:

- **#16 SCRAM hash leak**: `chargemecar/csms/.docker/pgbouncer/userlist.txt`
  contains real SCRAM-SHA-256 hashes for 6 platform roles. Rotate the
  passwords + scrub git history with `git filter-repo`.
- **#17 WireGuard key leak**: `chargemecar/.../wireguard/` and
  `ocpp-css/.../wireguard/` contain real private keys (server + peer).
  Rotate keys + scrub git history. plugme is clean.

Both cleanups happen in the live brand-repos — not here in the
template.
