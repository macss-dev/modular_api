"""Tests for UseCaseException."""

from __future__ import annotations

import pytest

from modular_api.core.use_case_exception import UseCaseException


class TestUseCaseException:
    def test_stores_all_properties(self) -> None:
        exc = UseCaseException(
            status_code=404,
            message="User not found",
            error_code="USER_NOT_FOUND",
            details={"userId": 123},
        )
        assert exc.status_code == 404
        assert exc.message == "User not found"
        assert exc.error_code == "USER_NOT_FOUND"
        assert exc.details == {"userId": 123}

    def test_to_json_includes_error_and_message(self) -> None:
        exc = UseCaseException(
            status_code=400,
            message="Invalid input",
            error_code="VALIDATION_ERROR",
        )
        json = exc.to_json()
        assert json["error"] == "VALIDATION_ERROR"
        assert json["message"] == "Invalid input"
        assert "details" not in json

    def test_to_json_includes_details_when_provided(self) -> None:
        exc = UseCaseException(
            status_code=422,
            message="Account inactive",
            error_code="ACCOUNT_INACTIVE",
            details={"status": "suspended"},
        )
        json = exc.to_json()
        assert json["error"] == "ACCOUNT_INACTIVE"
        assert json["message"] == "Account inactive"
        assert json["details"] == {"status": "suspended"}

    def test_to_json_uses_error_as_default_error_code(self) -> None:
        exc = UseCaseException(
            status_code=500,
            message="Internal error",
        )
        json = exc.to_json()
        assert json["error"] == "error"
        assert json["message"] == "Internal error"

    def test_str_with_error_code(self) -> None:
        exc = UseCaseException(
            status_code=404,
            message="Not found",
            error_code="RESOURCE_NOT_FOUND",
        )
        assert str(exc) == "UseCaseException(404): Not found [RESOURCE_NOT_FOUND]"

    def test_str_without_error_code(self) -> None:
        exc = UseCaseException(
            status_code=400,
            message="Bad request",
        )
        assert str(exc) == "UseCaseException(400): Bad request"

    def test_is_exception(self) -> None:
        exc = UseCaseException(status_code=500, message="fail")
        assert isinstance(exc, Exception)

    def test_can_be_raised_and_caught(self) -> None:
        with pytest.raises(UseCaseException) as exc_info:
            raise UseCaseException(
                status_code=404,
                message="Resource not found",
                error_code="NOT_FOUND",
            )
        assert exc_info.value.status_code == 404
        assert exc_info.value.error_code == "NOT_FOUND"
