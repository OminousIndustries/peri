"""API error type. Every error leaves the server as ``{"error": {"code": "snake_case", "message": "..."}}``."""
from __future__ import annotations

from typing import Any, Dict


class ApiError(Exception):
    """An error with an HTTP status and a stable machine-readable code (see docs/API.md)."""

    def __init__(self, http_status: int, code: str, message: str, **extra: Any) -> None:
        super().__init__(message)
        self.status = http_status          # extra fields (e.g. the upstream ``status``) may reuse the name 'status'

        self.code = code
        self.message = message
        self.extra: Dict[str, Any] = extra

    def body(self) -> Dict[str, Any]:
        err: Dict[str, Any] = {"code": self.code, "message": self.message}
        err.update(self.extra)
        return {"error": err}


def bad_request(message: str, code: str = "bad_request", **extra: Any) -> ApiError:
    return ApiError(400, code, message, **extra)


def not_found(message: str = "not found") -> ApiError:
    return ApiError(404, "not_found", message)


def forbidden(message: str = "this endpoint is only available from the device itself") -> ApiError:
    return ApiError(403, "forbidden", message)


def unauthorized(message: str = "missing or invalid bearer token") -> ApiError:
    return ApiError(401, "unauthorized", message)


def unavailable(code: str, message: str, status: int = 503) -> ApiError:
    return ApiError(status, code, message)
