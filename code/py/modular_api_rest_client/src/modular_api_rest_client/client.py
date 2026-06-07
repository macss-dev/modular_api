from __future__ import annotations

import json
import socket
import time
import urllib.error
import urllib.parse
import urllib.request
from dataclasses import dataclass, field
from enum import Enum
from typing import Any, Callable, Generic, Mapping, TypeVar, cast

T = TypeVar("T")
_MISSING = object()

ServiceDecoder = Callable[[object | None], T]
ServiceAuthProvider = Callable[["ServiceOperation"], Mapping[str, str]]


@dataclass(frozen=True, slots=True)
class ServiceRetryPolicy:
    max_attempts: int = 1


@dataclass(frozen=True, slots=True)
class ServiceTelemetryHooks:
    on_started: Callable[["ServiceOperation"], None] | None = None
    on_completed: Callable[["ServiceOperation", "ServiceResult[object]"], None] | None = None


@dataclass(frozen=True, slots=True)
class ServiceClientConfig:
    service_id: str
    base_url: str
    redacted_summary: str
    default_headers: Mapping[str, str] = field(default_factory=dict)
    auth_provider: ServiceAuthProvider | None = None
    timeout: float | None = None
    retry_policy: ServiceRetryPolicy | None = None
    user_agent: str | None = None
    telemetry_hooks: ServiceTelemetryHooks | None = None


@dataclass(frozen=True, slots=True)
class ServiceOperation:
    transport_id: str
    operation_id: str
    headers: Mapping[str, str] = field(default_factory=dict)
    method: str | None = None
    path: str | None = None
    query: Mapping[str, object] | None = None
    body: object | None = None
    document: str | None = None
    variables: Mapping[str, object] | None = None
    operation_name: str | None = None


class ServiceRequest(ServiceOperation):
    def __init__(
        self,
        *,
        operation_id: str,
        method: str,
        path: str,
        headers: Mapping[str, str] | None = None,
        query: Mapping[str, object] | None = None,
        body: object | None = None,
    ) -> None:
        super().__init__(
            transport_id="http",
            operation_id=operation_id,
            headers={} if headers is None else dict(headers),
            method=method,
            path=path,
            query=query,
            body=body,
        )


@dataclass(frozen=True, slots=True)
class ServiceResponseMetadata:
    status_code: int
    headers: Mapping[str, str]
    transport_id: str
    duration: float
    request_id: str | None = None


@dataclass(frozen=True, slots=True)
class ServiceResponse(Generic[T]):
    data: T
    metadata: ServiceResponseMetadata


class ServiceFailureCategory(str, Enum):
    TRANSPORT = "transport"
    TIMEOUT = "timeout"
    AUTH = "auth"
    RATE_LIMIT = "rate_limit"
    PROTOCOL = "protocol"
    DECODE = "decode"
    GRAPHQL = "graphql"
    UNEXPECTED = "unexpected"


@dataclass(frozen=True, slots=True)
class ServiceFailure:
    category: ServiceFailureCategory
    code: str
    message: str
    retryable: bool
    status_code: int | None = None
    transport_id: str | None = None
    details: object | None = None
    cause_summary: str | None = None


class ServiceResult(Generic[T]):
    def __init__(
        self,
        value: object = _MISSING,
        failure: ServiceFailure | None = None,
    ) -> None:
        self._value = value
        self._failure = failure

    @classmethod
    def success(cls, value: T) -> ServiceResult[T]:
        return cls(value=value)

    @classmethod
    def from_failure(cls, failure: ServiceFailure) -> ServiceResult[T]:
        return cls(failure=failure)

    @property
    def is_success(self) -> bool:
        return self._failure is None

    @property
    def is_failure(self) -> bool:
        return self._failure is not None

    @property
    def value(self) -> T:
        if self._failure is not None or self._value is _MISSING:
            raise RuntimeError("ServiceResult does not contain a success value.")
        return cast(T, self._value)

    @property
    def failure(self) -> ServiceFailure:
        if self._failure is None:
            raise RuntimeError("ServiceResult does not contain a failure value.")
        return self._failure


@dataclass(frozen=True, slots=True)
class ServiceClientDescription:
    service_id: str
    transport_id: str
    base_url: str
    redacted_summary: str


class HttpServiceClient:
    def __init__(self, config: ServiceClientConfig) -> None:
        self._config = config
        self._opener = urllib.request.build_opener()
        self._closed = False

    def describe(self) -> ServiceClientDescription:
        return ServiceClientDescription(
            service_id=self._config.service_id,
            transport_id="http",
            base_url=self._config.base_url,
            redacted_summary=self._config.redacted_summary,
        )

    def execute(
        self,
        operation: ServiceOperation,
        *,
        decoder: ServiceDecoder[T] | None = None,
    ) -> ServiceResult[ServiceResponse[T]]:
        if self._closed:
            return ServiceResult.from_failure(
                ServiceFailure(
                    category=ServiceFailureCategory.UNEXPECTED,
                    code="client_closed",
                    message="The HTTP service client is already closed.",
                    retryable=False,
                    transport_id="http",
                )
            )

        if operation.transport_id != "http" or operation.method is None or operation.path is None:
            return ServiceResult.from_failure(
                ServiceFailure(
                    category=ServiceFailureCategory.PROTOCOL,
                    code="invalid_operation",
                    message="HTTP execution requires transportId, method, and path.",
                    retryable=False,
                    transport_id="http",
                )
            )

        self._config.telemetry_hooks.on_started(operation) if self._config.telemetry_hooks and self._config.telemetry_hooks.on_started else None

        started_at = time.monotonic()
        result: ServiceResult[ServiceResponse[T]]

        try:
            headers = self._build_headers(operation)
            request = urllib.request.Request(
                _resolve_url(self._config.base_url, operation.path, operation.query),
                data=_encode_body(operation.body, headers),
                headers=headers,
                method=operation.method,
            )

            with self._opener.open(request, timeout=self._config.timeout) as response:
                status_code = getattr(response, "status", response.getcode())
                response_text = response.read().decode("utf-8")
                header_map = _headers_to_record(response.headers)

                decoded = _decode_body(response_text, response.headers.get_content_type(), decoder)
                if isinstance(decoded, ServiceFailure):
                    result = ServiceResult.from_failure(decoded)
                else:
                    result = ServiceResult.success(
                        ServiceResponse(
                            data=decoded,
                            metadata=ServiceResponseMetadata(
                                status_code=status_code,
                                headers=header_map,
                                transport_id="http",
                                duration=time.monotonic() - started_at,
                                request_id=header_map.get("x-request-id"),
                            ),
                        )
                    )
        except urllib.error.HTTPError as error:
            details = error.read().decode("utf-8")
            result = ServiceResult.from_failure(
                ServiceFailure(
                    category=_category_for_status(error.code),
                    code=_code_for_status(error.code),
                    message=details if details else f"HTTP request failed with status {error.code}.",
                    retryable=_is_retryable_status(error.code),
                    status_code=error.code,
                    transport_id="http",
                    details=details if details else None,
                )
            )
        except urllib.error.URLError as error:
            reason = error.reason
            if isinstance(reason, (TimeoutError, socket.timeout)):
                result = ServiceResult.from_failure(
                    ServiceFailure(
                        category=ServiceFailureCategory.TIMEOUT,
                        code="timeout",
                        message="The HTTP request timed out.",
                        retryable=True,
                        transport_id="http",
                        cause_summary=str(reason),
                    )
                )
            else:
                result = ServiceResult.from_failure(
                    ServiceFailure(
                        category=ServiceFailureCategory.TRANSPORT,
                        code="transport_error",
                        message="The HTTP request failed to reach the remote service.",
                        retryable=True,
                        transport_id="http",
                        cause_summary=str(reason),
                    )
                )
        except (TimeoutError, socket.timeout) as error:
            result = ServiceResult.from_failure(
                ServiceFailure(
                    category=ServiceFailureCategory.TIMEOUT,
                    code="timeout",
                    message="The HTTP request timed out.",
                    retryable=True,
                    transport_id="http",
                    cause_summary=str(error),
                )
            )
        except Exception as error:  # noqa: BLE001
            result = ServiceResult.from_failure(
                ServiceFailure(
                    category=ServiceFailureCategory.UNEXPECTED,
                    code="unexpected_error",
                    message="The HTTP request failed unexpectedly.",
                    retryable=False,
                    transport_id="http",
                    cause_summary=str(error),
                )
            )

        if self._config.telemetry_hooks and self._config.telemetry_hooks.on_completed:
            self._config.telemetry_hooks.on_completed(operation, cast(ServiceResult[object], result))
        return result

    def close(self) -> ServiceResult[None]:
        self._closed = True
        return ServiceResult.success(None)

    def _build_headers(self, operation: ServiceOperation) -> dict[str, str]:
        headers = {
            **dict(self._config.default_headers),
            **dict(operation.headers),
        }

        if self._config.auth_provider is not None:
            headers.update(dict(self._config.auth_provider(operation)))

        if self._config.user_agent is not None and "User-Agent" not in headers and "user-agent" not in headers:
            headers["User-Agent"] = self._config.user_agent

        return headers


def http_client(
    *,
    config: ServiceClientConfig,
    request: ServiceRequest,
    decoder: ServiceDecoder[T] | None = None,
) -> ServiceResult[ServiceResponse[T]]:
    client = HttpServiceClient(config)
    try:
        return client.execute(request, decoder=decoder)
    finally:
        client.close()


def _resolve_url(base_url: str, path: str, query: Mapping[str, object] | None) -> str:
    base = urllib.parse.urlsplit(base_url)
    path_segments = [segment for segment in base.path.split("/") if segment]
    path_segments.extend(segment for segment in path.lstrip("/").split("/") if segment)
    normalized_path = "/" + "/".join(path_segments)

    query_string = urllib.parse.urlencode(
        {
            key: str(value)
            for key, value in (query or {}).items()
            if value is not None
        }
    )

    return urllib.parse.urlunsplit(
        (base.scheme, base.netloc, normalized_path, query_string, "")
    )


def _encode_body(body: object | None, headers: dict[str, str]) -> bytes | None:
    if body is None:
        return None

    if "Content-Type" not in headers and "content-type" not in headers:
        headers["Content-Type"] = "application/json"

    return json.dumps(body).encode("utf-8")


def _headers_to_record(headers: Any) -> dict[str, str]:
    return {key.lower(): value for key, value in headers.items()}


def _decode_body(
    body: str,
    content_type: str | None,
    decoder: ServiceDecoder[T] | None,
) -> T | ServiceFailure:
    if body == "":
        decoded: object | None = None
    elif _looks_like_json(content_type, body):
        try:
            decoded = json.loads(body)
        except json.JSONDecodeError as error:
            return ServiceFailure(
                category=ServiceFailureCategory.DECODE,
                code="invalid_json",
                message="The HTTP response body is not valid JSON.",
                retryable=False,
                transport_id="http",
                cause_summary=str(error),
            )
    else:
        decoded = body

    return decoder(decoded) if decoder is not None else cast(T, decoded)


def _looks_like_json(content_type: str | None, body: str) -> bool:
    if content_type is not None:
        normalized = content_type.lower()
        if normalized == "application/json" or normalized.endswith("+json"):
            return True

    trimmed = body.lstrip()
    return trimmed.startswith("{") or trimmed.startswith("[")


def _category_for_status(status_code: int) -> ServiceFailureCategory:
    if status_code in {401, 403}:
        return ServiceFailureCategory.AUTH
    if status_code == 429:
        return ServiceFailureCategory.RATE_LIMIT
    return ServiceFailureCategory.PROTOCOL


def _code_for_status(status_code: int) -> str:
    if status_code == 401:
        return "unauthorized"
    if status_code == 403:
        return "forbidden"
    if status_code == 429:
        return "rate_limit"
    return f"http_{status_code}"


def _is_retryable_status(status_code: int) -> bool:
    return status_code == 429 or status_code >= 500