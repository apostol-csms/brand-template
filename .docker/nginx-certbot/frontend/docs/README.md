# `frontend/docs` - Swagger UI served at `/docs/`

The nginx image bakes this directory in (`Dockerfile: COPY ./frontend/docs /var/www/docs`) and
`includes/proxy-backend.conf` serves it as `location ^~ /docs/`. `index.html` lists two documents:
`/docs/api.yaml` (API v1) and `/docs/api-v2.yaml` (API v2).

The documents are not kept here. `brands/_lib/mk-openapi.py` builds
`.docker/nginx-certbot/docs-templates/{api,api-v2}.yaml.template` from `db/api/openapi.yaml` and
`go/openapi/api-v2.json` (`x-*` markers dropped; API v2 converted from OpenAPI 3.1 to 3.0.3 for this
Swagger UI bundle). The image copies the templates to `/etc/nginx/docs.d`; `entrypoint.sh` renders
`api.yaml`, `api-v2.yaml` and `oauth-config.js` into `/var/www/docs` with `envsubst`: client
`web-$DOMAIN`, scope `https://$DOMAIN`.

```bash
python3 brands/_lib/mk-openapi.py          # regenerate after a source changed
python3 brands/_lib/mk-openapi.py --check  # rc=1 when a template is stale (run before a build)
```
