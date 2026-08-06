# `frontend/docs` — Swagger UI served at `/docs/`

The nginx image bakes this directory in (`Dockerfile: COPY ./frontend/docs
/var/www/docs`) and `includes/proxy-backend.conf` serves it as `location ^~
/docs/` on the `cloud`, `api`, `cpo`, `admin` and `cs` subdomains. `index.html`
loads the specification from `/docs/api.yaml`.

## `api.yaml` is not in this directory — generate it

The specification is per brand: the servers, the OAuth2 client and scope, and
which endpoint families belong in the profile all differ. It is produced from
the platform workspace, not edited here:

```bash
cd ~/DevSrc/Projects/apostol-csms
$EDITOR tools/mk-openapi.py          # add a profile for the new brand
python3 tools/mk-openapi.py --brand <brand>
```

The profile carries the brand's title, contact, API host, OAuth2 `client_id` and
`scope` (take them from the brand's `/api/v1/manifest`), and the endpoint
families to drop — a European deployment, for instance, ships without the
Russian payment providers and the address classifier.

**Build the nginx image only after the spec exists.** Without it the page loads
and then fails to fetch its own specification.

## Two Swagger UIs, on purpose

This one lives on the app subdomains. A brand may also publish a public API
reference on its landing (`<domain>/docs`) — see the `docs.vue` page in the
chargemecar and ocpp-css landing repos. Both read the same generated
specification, so they cannot drift apart.

## Assets

Only the files `index.html` actually loads are kept here: the bundle, the
standalone preset, the stylesheet, the favicons and the OAuth2 redirect page.
Source maps and the ES-module variants are omitted deliberately — they add
~5 MB to the repository and nothing to the running image.

`oauth2-redirect.html` completes the Authorize flow. The URL it is reached at
must be registered in `redirect_uris` of the `web` client in
`backend/docker/conf/oauth2/default.json`; the entries for the app subdomains
are already there.
