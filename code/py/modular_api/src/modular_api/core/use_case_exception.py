"""Structured exception for controlled HTTP error responses.

Throw inside ``execute()`` to return a specific HTTP status code and a
structured JSON error body — instead of a generic 500.

Example::

    raise UseCaseException(
        status_code=404,
        message="User not found",
        error_code="USER_NOT_FOUND",
    )

HTTP response body::

    {"error": "USER_NOT_FOUND", "message": "User not found"}
"""

from __future__ import annotations


class UseCaseException(Exception):
    """Exception that maps to a controlled HTTP error response."""

    def __init__(
        self,
        *,
        status_code: int,
        message: str,
        error_code: str | None = None,
        details: dict[str, object] | None = None,
    ) -> None:
        super().__init__(message)
        self.status_code = status_code
        self.message = message
        self.error_code = error_code
        self.details = details

    def to_json(self) -> dict[str, object]:
        """Serialize to the JSON body sent in the HTTP error response."""
        body: dict[str, object] = {
            "error": self.error_code or "error",
            "message": self.message,
        }
        if self.details is not None:
            body["details"] = self.details
        return body

    def __str__(self) -> str:
        code_suffix = f" [{self.error_code}]" if self.error_code else ""
        return f"UseCaseException({self.status_code}): {self.message}{code_suffix}"
