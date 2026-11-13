# payment-test

A stand-in payment provider behind the payment-service contract. A database-side payment
adapter talks to it exactly as it talks to a real provider's service: it sends an operation,
gets an answer, and receives notifications. Nothing here moves money.

The contract is [`openapi.json`](openapi.json) (also served at `/openapi.json` and `/docs`).
A test keeps the file equal to what the code serves.

## Run

```sh
docker build -t payment-test .
docker run --rm -e SERVICE_KEY=<secret> -e NOTIFY_URL=http://backend:4977 payment-test
```

| Variable | Meaning |
|---|---|
| `SERVICE_KEY` | **Required.** Shared secret: every request must carry it in `X-Service-Key`, every notification carries it too. Without it the service does not start. |
| `NOTIFY_URL` | Base address of notifications; `/payment/notify/testpay` is appended. Default `http://backend:4977`. |
| `NOTIFY_TIMEOUT_S` | Timeout of one notification attempt, seconds. Default `5`. |
| `HOST`, `PORT` | Listen address. Default `0.0.0.0:8000`. |
| `LOG_LEVEL` | Default `INFO`. |

The service belongs on a private container network only. It has no rights of its own and
keeps nothing on disk: a restart forgets every payment.

## Operations

`POST /v1/{pay,capture,cancel,refund,status,bind,unbind}` with one envelope:
`{op, payment, idempotency_key, provider_id, amount, currency, capture, payment_method, credentials, return_url, metadata}`.

| Operation | Reads | Success role |
|---|---|---|
| `pay` | `payment`, `amount`, `currency`, `payment_method`, `capture` (default `false`) | `hold`, or `paid` with `capture: true` |
| `capture` | `provider_id`, `amount` (default: the held amount) | `paid` |
| `cancel` | `provider_id` | `canceled` |
| `refund` | `provider_id`, `amount` | `partial_refunded`, then `refunded` |
| `status` | `provider_id` | the current role |
| `bind` | `payment_method` (a test token) | — (`payment_method: {id, card}`) |
| `unbind` | `payment_method` (the id from `bind`) | — |

The answer to a well-formed request is always HTTP 200:
`{outcome: success|declined|unknown, role, provider_id, provider_status, error: {code, message}, payment_method, raw}`.
A dropped connection, or a status other than 200, 401 and 422, means the service itself is unavailable.
422 means a malformed envelope (the caller's bug): `amount` not like `100` / `100.00`, `payment_method`
not a string, `metadata.notify_delay_ms` not an integer 0–600000, a missing `idempotency_key`.
A business refusal is never 422: it is 200 with `outcome: declined` and `error.code`.

- `amount` is a decimal with at most two places (`"100.00"`); a JSON number is accepted too.
- `capture: null` is `false`.
- A payment is found by `provider_id`; `payment` is not compared on later operations.
- An unknown `provider_id`: `declined`, `role: null`, `error.code: payment_not_found`.
- A refund above what was paid: `declined`, `error.code: amount_exceeds`, the role unchanged.
- An operation in the wrong state: `declined`, `error.code: invalid_state`.
- `provider_status` is this provider's own vocabulary (`authorized`, `captured`, `voided`, …), not the role.

## Test scenarios

`payment_method` is a plain string: a test token, or the id of a saved method from `bind`, which
behaves as the token it was bound with. An object is refused with 422.

| Token | Answer |
|---|---|
| `test_ok` | `success` |
| `test_decline` | `declined`, `role: failed`, `error.code: card_declined` |
| `test_unknown` | `unknown`, `role: pending`, with `provider_id`; the operation did happen: `status` returns `hold` or `paid` |
| `test_drop` | the operation happens as with `test_ok`, then the connection is closed without a response |

The tokens drive `pay` and `bind` (and a payment with a saved method). `capture`, `cancel`, `refund`
and `unbind` always answer on the payment's books; their declined cases are a wrong state, an unknown
id or an amount above what is allowed. `bind` with `test_unknown` saves the method and still names it.

**Idempotency.** A repeat of the same operation with the same `idempotency_key` gets the first answer,
whatever its body — also after `test_drop`, where the repeat gets the recorded success. The same key on
another operation is a new call. `status` is a read and is never replayed.

**Key.** A missing or wrong `X-Service-Key` on `/v1/*` and `/test/*` is refused with 401
`{"error": {"code": "unauthorized"}}`, before the body is read. `/health`, `/docs` and `/openapi.json`
need no key.

## Notifications

After every operation that changes a payment, the service posts
`{event_id, provider_id, payment, role, provider_status, raw}` with `X-Service-Key` to
`NOTIFY_URL/payment/notify/testpay`, once, after `metadata.notify_delay_ms` (default 1000; `0` sends
at once; at most 600000). A notification still waiting when the service stops is dropped.

`POST /test/renotify/{provider_id}` sends the last event of that payment again, with the same
`event_id`: the case of a notification delivered twice. An unknown `provider_id` gets 404.

## Tests

```sh
docker run --rm -v "$PWD:/w" -w /w python:3.11-slim \
  sh -c 'pip install -q -r requirements-dev.txt && python -m pytest -q'
```

After a change of the routes or the envelopes, regenerate the contract:
`SERVICE_KEY=x python -m app.openapi > openapi.json`.
