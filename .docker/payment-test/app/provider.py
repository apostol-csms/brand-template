"""The imitated provider: payments and saved methods in memory.

The registry is the imitation of a provider's own books, not state of the
caller: a restart forgets everything, as a provider's sandbox reset would.
The provider has its own status names, mapped to the contract's roles, so a
caller that confuses the two is caught.
"""
from __future__ import annotations

import uuid
from dataclasses import dataclass, field
from decimal import Decimal
from typing import Optional

from app.models import TEST_TOKENS, Card, Error, Outcome, PaymentMethod, Request, Response, Role

# provider status -> role
ROLE_OF = {
    "pending": Role.pending,
    "authorized": Role.hold,
    "captured": Role.paid,
    "voided": Role.canceled,
    "partially_refunded": Role.partial_refunded,
    "refunded": Role.refunded,
    "declined": Role.failed,
}


@dataclass
class Payment:
    provider_id: str
    payment: Optional[str]
    amount: Decimal
    currency: Optional[str]
    status: str
    captured: Decimal = Decimal(0)
    refunded: Decimal = Decimal(0)

    def raw(self) -> dict:
        return {
            "id": self.provider_id,
            "status": self.status,
            "amount": str(self.amount),
            "captured_amount": str(self.captured),
            "refunded_amount": str(self.refunded),
            "currency": self.currency,
            "payment": self.payment,
        }


@dataclass
class SavedMethod:
    id: str
    token: str
    card: Card


@dataclass
class Result:
    """What an operation produced: the answer, and the payment whose new state
    is to be notified (None when nothing changed)."""

    response: Response
    notify: Optional[Payment] = None
    drop: bool = False


def _declined(code: str, message: str, p: Optional[Payment] = None) -> Response:
    return Response(
        outcome=Outcome.declined,
        role=ROLE_OF[p.status] if p else None,
        provider_id=p.provider_id if p else None,
        provider_status=p.status if p else None,
        error=Error(code=code, message=message),
        raw=p.raw() if p else {},
    )


def _success(p: Payment) -> Response:
    return Response(outcome=Outcome.success, role=ROLE_OF[p.status], provider_id=p.provider_id,
                    provider_status=p.status, raw=p.raw())


@dataclass
class Provider:
    payments: dict[str, Payment] = field(default_factory=dict)
    methods: dict[str, SavedMethod] = field(default_factory=dict)

    def _scenario(self, payment_method: Optional[str]) -> Optional[str]:
        """The test token behind a payment method, or None when there is none."""
        if not payment_method:
            return None
        if payment_method in TEST_TOKENS:
            return payment_method
        m = self.methods.get(payment_method)
        return m.token if m else None

    def _find(self, req: Request) -> Optional[Payment]:
        return self.payments.get(req.provider_id or "")

    def pay(self, req: Request) -> Result:
        token = self._scenario(req.payment_method)
        if token is None:
            return Result(_declined("invalid_payment_method", "unknown payment method"))
        if req.amount is None:
            return Result(_declined("invalid_amount", "amount is required"))
        p = Payment(provider_id=f"tp_{uuid.uuid4().hex}", payment=req.payment, amount=req.amount,
                    currency=req.currency, status="pending")
        self.payments[p.provider_id] = p
        if token == "test_decline":
            p.status = "declined"
            r = _declined("card_declined", "the card was declined", p)
            return Result(r, notify=p)
        if req.capture:
            p.status, p.captured = "captured", p.amount
        else:
            p.status = "authorized"
        if token == "test_unknown":
            # The provider did the operation, the answer says nothing certain:
            # status(provider_id) tells the truth, the notification follows.
            r = Response(outcome=Outcome.unknown, role=Role.pending, provider_id=p.provider_id,
                         provider_status="pending", raw={"id": p.provider_id})
            return Result(r, notify=p)
        return Result(_success(p), notify=p, drop=token == "test_drop")

    def capture(self, req: Request) -> Result:
        p = self._find(req)
        if p is None:
            return Result(_declined("payment_not_found", "no such payment"))
        if p.status != "authorized":
            return Result(_declined("invalid_state", f"cannot capture a payment in status {p.status}", p))
        amount = req.amount if req.amount is not None else p.amount
        if amount > p.amount:
            return Result(_declined("amount_exceeds", "capture above the held amount", p))
        p.status, p.captured = "captured", amount
        return Result(_success(p), notify=p)

    def cancel(self, req: Request) -> Result:
        p = self._find(req)
        if p is None:
            return Result(_declined("payment_not_found", "no such payment"))
        if p.status != "authorized":
            return Result(_declined("invalid_state", f"cannot cancel a payment in status {p.status}", p))
        p.status = "voided"
        return Result(_success(p), notify=p)

    def refund(self, req: Request) -> Result:
        p = self._find(req)
        if p is None:
            return Result(_declined("payment_not_found", "no such payment"))
        if p.status not in ("captured", "partially_refunded"):
            return Result(_declined("invalid_state", f"cannot refund a payment in status {p.status}", p))
        if req.amount is None:
            return Result(_declined("invalid_amount", "amount is required", p))
        if p.refunded + req.amount > p.captured:
            return Result(_declined("amount_exceeds", "refund above the paid amount", p))
        p.refunded += req.amount
        p.status = "refunded" if p.refunded == p.captured else "partially_refunded"
        return Result(_success(p), notify=p)

    def status(self, req: Request) -> Result:
        p = self._find(req)
        if p is None:
            return Result(_declined("payment_not_found", "no such payment"))
        return Result(_success(p))

    def bind(self, req: Request) -> Result:
        token = self._scenario(req.payment_method)
        if token is None or req.payment_method not in TEST_TOKENS:
            return Result(_declined("invalid_payment_method", "bind takes a test token"))
        if token == "test_decline":
            return Result(_declined("card_declined", "the card was declined"))
        m = SavedMethod(id=f"pm_{uuid.uuid4().hex}", token=token, card=Card(brand="test", last4="0000"))
        self.methods[m.id] = m
        pm = PaymentMethod(id=m.id, card=m.card)
        if token == "test_unknown":
            # The method was saved; the answer is uncertain but still names it.
            return Result(Response(outcome=Outcome.unknown, payment_method=pm, raw={"id": m.id}))
        r = Response(outcome=Outcome.success, payment_method=pm, raw={"id": m.id, "token": token})
        return Result(r, drop=token == "test_drop")

    def unbind(self, req: Request) -> Result:
        m = self.methods.pop(req.payment_method or "", None)
        if m is None:
            return Result(_declined("payment_method_not_found", "no such saved method"))
        return Result(Response(outcome=Outcome.success, payment_method=PaymentMethod(id=m.id, card=m.card),
                               raw={"id": m.id, "deleted": True}))
