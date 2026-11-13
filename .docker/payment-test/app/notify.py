"""Notifications: the provider's own call back to the caller.

One attempt per event; a repeat is asked for through the test hook
POST /test/renotify/{provider_id}, which sends the last event of that payment
again with the same event_id.
"""
from __future__ import annotations

import asyncio
import logging
import uuid
from typing import Optional

import httpx

from app.models import Notification
from app.provider import ROLE_OF, Payment

log = logging.getLogger("payment-test.notify")

NOTIFY_PATH = "/payment/notify/testpay"


class Notifier:
    def __init__(self, base_url: str, key: str, timeout_s: float):
        self.url = base_url + NOTIFY_PATH
        self.key = key
        self.timeout_s = timeout_s
        self.last: dict[str, Notification] = {}
        self._tasks: set[asyncio.Task] = set()

    def event_of(self, p: Payment) -> Notification:
        n = Notification(event_id=str(uuid.uuid4()), provider_id=p.provider_id, payment=p.payment,
                         role=ROLE_OF[p.status], provider_status=p.status, raw=p.raw())
        self.last[p.provider_id] = n
        return n

    def schedule(self, n: Notification, delay_ms: int) -> None:
        t = asyncio.get_running_loop().create_task(self._send_later(n, delay_ms))
        self._tasks.add(t)
        t.add_done_callback(self._tasks.discard)

    async def _send_later(self, n: Notification, delay_ms: int) -> None:
        if delay_ms:
            await asyncio.sleep(delay_ms / 1000)
        await self.send(n)

    async def send(self, n: Notification) -> Optional[int]:
        try:
            async with httpx.AsyncClient(timeout=self.timeout_s, trust_env=False) as c:
                r = await c.post(self.url, json=n.model_dump(mode="json"), headers={"X-Service-Key": self.key})
            log.info("notify %s %s role=%s -> %s", n.event_id, n.provider_id, n.role.value, r.status_code)
            return r.status_code
        except Exception as e:  # noqa: BLE001 — a notification failure is logged, never raised
            log.warning("notify %s %s role=%s failed: %s", n.event_id, n.provider_id, n.role.value,
                        type(e).__name__)
            return None

    async def cancel_pending(self) -> None:
        """On shutdown: a delayed notification not yet sent is dropped, as a
        provider's sandbox would drop it; shutdown never waits for it."""
        for t in list(self._tasks):
            t.cancel()
        await asyncio.gather(*list(self._tasks), return_exceptions=True)
