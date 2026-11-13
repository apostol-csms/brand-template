"""Configuration from the environment.

SERVICE_KEY  required. The shared secret of the caller and this service: every
             request must carry it in X-Service-Key, and every notification
             this service sends carries it too.
NOTIFY_URL   base address notifications are posted to; the path
             /payment/notify/testpay is appended. Default http://backend:4977.
NOTIFY_TIMEOUT_S  timeout of one notification attempt, seconds. Default 5.
LOG_LEVEL    default INFO.
"""
from __future__ import annotations

import os
from dataclasses import dataclass


class ConfigError(RuntimeError):
    pass


@dataclass(frozen=True)
class Settings:
    service_key: str
    notify_url: str
    notify_timeout_s: float
    log_level: str


def load() -> Settings:
    key = os.environ.get("SERVICE_KEY", "")
    if not key.strip():
        raise ConfigError("SERVICE_KEY is not set: the service does not start without it")
    if key != key.strip() or not key.isascii() or not key.isprintable():
        raise ConfigError("SERVICE_KEY must be printable ASCII without surrounding whitespace")
    try:
        timeout = float(os.environ.get("NOTIFY_TIMEOUT_S", "5"))
    except ValueError as e:
        raise ConfigError("NOTIFY_TIMEOUT_S must be a number of seconds") from e
    return Settings(
        service_key=key,
        notify_url=os.environ.get("NOTIFY_URL", "http://backend:4977").rstrip("/"),
        notify_timeout_s=timeout,
        log_level=os.environ.get("LOG_LEVEL", "INFO"),
    )
