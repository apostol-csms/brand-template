"""payment-test: a stand-in payment provider behind the payment-service contract.

Routes:
  POST /v1/{pay,capture,cancel,refund,status,bind,unbind}  the operations
  POST /test/renotify/{provider_id}                       send the last event again
  GET  /health, /docs, /openapi.json                      no key needed

Every /v1 and /test route requires X-Service-Key equal to SERVICE_KEY (401
otherwise). An answer is HTTP 200 with the response envelope; a repeat with
the same idempotency_key gets the first answer, whatever its body.
"""
from __future__ import annotations

import asyncio
import hmac
import logging
from contextlib import asynccontextmanager
from typing import Any, Callable

from fastapi import Depends, FastAPI, Header, HTTPException, Request as HttpRequest
from fastapi.encoders import jsonable_encoder
from fastapi.exceptions import RequestValidationError
from fastapi.responses import JSONResponse
from starlette.exceptions import HTTPException as StarletteHTTPException

from app import config
from app.models import Op, Request, Response
from app.notify import Notifier
from app.provider import Provider, Result

settings = config.load()

logging.basicConfig(level=getattr(logging, settings.log_level.upper(), logging.INFO))
log = logging.getLogger("payment-test")

DROP_FLAG = "payment_test.drop"


class State:
    def __init__(self) -> None:
        self.provider = Provider()
        self.notifier = Notifier(settings.notify_url, settings.service_key, settings.notify_timeout_s)
        # (operation, idempotency_key) -> the first answer. status is not
        # recorded: it is a read, and a poll must see the payment move.
        self.answers: dict[tuple[str, str], dict[str, Any]] = {}
        self.lock = asyncio.Lock()


state = State()


@asynccontextmanager
async def lifespan(_: FastAPI):
    yield
    await state.notifier.cancel_pending()


api = FastAPI(
    title="payment-test",
    version="0.1.0",
    description=__doc__,
    lifespan=lifespan,
)


def _refuse(status: int, code: str, message: str) -> JSONResponse:
    return JSONResponse(status_code=status, content={"error": {"code": code, "message": message}})


@api.exception_handler(StarletteHTTPException)
async def _http_error(_: HttpRequest, exc: HTTPException) -> JSONResponse:
    code = "unauthorized" if exc.status_code == 401 else "not_found" if exc.status_code == 404 else "error"
    return _refuse(exc.status_code, code, str(exc.detail))


@api.exception_handler(RequestValidationError)
async def _invalid(_: HttpRequest, exc: RequestValidationError) -> JSONResponse:
    return JSONResponse(status_code=422, content={"error": {"code": "invalid_request", "message": "malformed request",
                                                           "details": jsonable_encoder(exc.errors())}})


def check_key(x_service_key: str | None) -> None:
    if not x_service_key or not hmac.compare_digest(x_service_key.encode(), settings.service_key.encode()):
        raise HTTPException(status_code=401, detail="missing or wrong X-Service-Key")


OPS: dict[Op, Callable[[Provider, Request], Result]] = {
    Op.pay: Provider.pay,
    Op.capture: Provider.capture,
    Op.cancel: Provider.cancel,
    Op.refund: Provider.refund,
    Op.status: Provider.status,
    Op.bind: Provider.bind,
    Op.unbind: Provider.unbind,
}


async def run(op: Op, body: Request, http: HttpRequest) -> dict[str, Any]:
    async with state.lock:
        slot = (op.value, body.idempotency_key)
        first = state.answers.get(slot) if op is not Op.status else None
        if first is not None:
            log.info("%s repeat of key: first answer", op.value)
            return first
        result = OPS[op](state.provider, body)
        answer = result.response.model_dump(mode="json")
        if op is not Op.status:
            state.answers[slot] = answer
        if result.notify is not None:
            state.notifier.schedule(state.notifier.event_of(result.notify), body.notify_delay_ms())
    log.info("%s -> %s %s%s", op.value, answer["outcome"], answer.get("role"), " (dropped)" if result.drop else "")
    if result.drop:
        http.scope[DROP_FLAG] = True
    return answer


def require_key(x_service_key: str | None = Header(default=None)) -> None:
    check_key(x_service_key)


KEYED = {"dependencies": [Depends(require_key)],
         "responses": {401: {"description": "missing or wrong X-Service-Key"}}}


def _route(op: Op) -> None:
    async def handler(body: Request, http: HttpRequest) -> dict[str, Any]:
        return await run(op, body, http)

    handler.__name__ = f"op_{op.value}"
    api.post(f"/v1/{op.value}", response_model=Response, summary=op.value, **KEYED)(handler)


for _op in Op:
    _route(_op)


@api.post("/test/renotify/{provider_id}", summary="send the last event of a payment again",
          dependencies=KEYED["dependencies"],
          responses={**KEYED["responses"], 404: {"description": "no event for this provider_id"}})
async def renotify(provider_id: str) -> dict[str, Any]:
    n = state.notifier.last.get(provider_id)
    if n is None:
        raise HTTPException(status_code=404, detail="no event for this provider_id")
    status = await state.notifier.send(n)
    return {"event_id": n.event_id, "delivered_status": status}


@api.get("/health")
async def health() -> dict:
    return {"status": "ok"}


KEYED_PREFIXES = ("/v1/", "/test/")


def _header(scope, name: bytes) -> str | None:
    for k, v in scope.get("headers", ()):
        if k == name:
            return v.decode("latin-1")
    return None


class DropConnection:
    """Outermost ASGI layer.

    1. The key: /v1 and /test answer 401 here, before the body is read.
    2. The drop: a handler that sets DROP_FLAG in the scope gets its connection
       closed without a response — the "network failure" scenario. The answer
       was already recorded under its idempotency key. It reaches uvicorn's
       transport through the server's own send; uvicorn then logs that the app
       returned without a response — expected for this scenario.
    """

    def __init__(self, app):
        self.app = app

    async def __call__(self, scope, receive, send):
        if scope["type"] != "http":
            return await self.app(scope, receive, send)

        if scope["path"].startswith(KEYED_PREFIXES):
            try:
                check_key(_header(scope, b"x-service-key"))
            except HTTPException as e:
                return await _refuse(e.status_code, "unauthorized", str(e.detail))(scope, receive, send)

        async def guarded(message):
            if scope.get(DROP_FLAG):
                transport = getattr(getattr(send, "__self__", None), "transport", None)
                if transport is None:
                    raise ConnectionAbortedError("payment-test: connection dropped by scenario")
                transport.abort()
                return
            await send(message)

        await self.app(scope, receive, guarded)


app = DropConnection(api)
