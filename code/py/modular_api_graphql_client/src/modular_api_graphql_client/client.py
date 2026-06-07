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

GraphqlDecoder = Callable[[object | None], T]
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


class GraphqlRequest(ServiceOperation):
    def __init__(
        self,
        *,
        operation_id: str,
        document: str,
        headers: Mapping[str, str] | None = None,
        variables: Mapping[str, object] | None = None,
        operation_name: str | None = None,
        path: str = "/graphql",
    ) -> None:
        super().__init__(
            transport_id="graphql",
            operation_id=operation_id,
            headers={} if headers is None else dict(headers),
            method="POST",
            path=path,
            document=document,
            variables=None if variables is None else dict(variables),
            operation_name=operation_name,
        )


@dataclass(frozen=True, slots=True)
class ServiceResponseMetadata:
    status_code: int
    headers: Mapping[str, str]
    transport_id: str
    duration: float
    request_id: str | None = None


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


@dataclass(frozen=True, slots=True)
class GraphqlErrorLocation:
    line: int
    column: int


@dataclass(frozen=True, slots=True)
class GraphqlError:
    message: str
    path: list[object] = field(default_factory=list)
    locations: list[GraphqlErrorLocation] = field(default_factory=list)
    extensions: dict[str, object] | None = None


@dataclass(frozen=True, slots=True)
class GraphqlResponse(Generic[T]):
    data: T | None
    errors: list[GraphqlError]
    metadata: ServiceResponseMetadata
    extensions: dict[str, object] | None = None


class GraphqlClient:
    def __init__(self, config: ServiceClientConfig) -> None:
        self._config = config
        self._opener = urllib.request.build_opener()
        self._closed = False

    def describe(self) -> ServiceClientDescription:
        return ServiceClientDescription(
            service_id=self._config.service_id,
            transport_id="graphql",
            base_url=self._config.base_url,
            redacted_summary=self._config.redacted_summary,
        )

    def execute(
        self,
        request: GraphqlRequest,
        *,
        decoder: GraphqlDecoder[T] | None = None,
    ) -> ServiceResult[GraphqlResponse[T]]:
        if self._closed:
            return ServiceResult.from_failure(
                ServiceFailure(
                    category=ServiceFailureCategory.UNEXPECTED,
                    code="client_closed",
                    message="The GraphQL client is already closed.",
                    retryable=False,
                    transport_id="graphql",
                )
            )

        if _is_mutation_document(request.document or ""):
            return ServiceResult.from_failure(
                ServiceFailure(
                    category=ServiceFailureCategory.GRAPHQL,
                    code="mutation_not_supported",
                    message="GraphQL mutations are not supported in v1.",
                    retryable=False,
                    transport_id="graphql",
                )
            )

        if self._config.telemetry_hooks and self._config.telemetry_hooks.on_started:
            self._config.telemetry_hooks.on_started(request)

        started_at = time.monotonic()
        result: ServiceResult[GraphqlResponse[T]]

        try:
            headers = self._build_headers(request)
            payload: dict[str, object] = {"query": request.document or ""}
            if request.variables is not None:
                payload["variables"] = dict(request.variables)
            if request.operation_name is not None:
                payload["operationName"] = request.operation_name

            http_request = urllib.request.Request(
                _resolve_url(self._config.base_url, request.path or "/graphql"),
                data=_encode_body(payload, headers),
                headers=headers,
                method="POST",
            )

            with self._opener.open(http_request, timeout=self._config.timeout) as response:
                status_code = getattr(response, "status", response.getcode())
                response_text = response.read().decode("utf-8")
                header_map = _headers_to_record(response.headers)
                envelope = _decode_envelope(response_text, response.headers.get_content_type())
                if isinstance(envelope, ServiceFailure):
                    result = ServiceResult.from_failure(envelope)
                else:
                    decoded = _decode_data(envelope.get("data"), decoder)
                    if isinstance(decoded, ServiceFailure):
                        result = ServiceResult.from_failure(decoded)
                    else:
                        result = ServiceResult.success(
                            GraphqlResponse(
                                data=decoded,
                                errors=_parse_errors(envelope.get("errors")),
                                extensions=_parse_extensions(envelope.get("extensions")),
                                metadata=ServiceResponseMetadata(
                                    status_code=status_code,
                                    headers=header_map,
                                    transport_id="graphql",
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
                    message="The GraphQL request failed unexpectedly.",
                    retryable=False,
                    transport_id="graphql",
                    cause_summary=str(error),
                )
            )

        if self._config.telemetry_hooks and self._config.telemetry_hooks.on_completed:
            self._config.telemetry_hooks.on_completed(request, cast(ServiceResult[object], result))
        return result

    def close(self) -> ServiceResult[None]:
        self._closed = True
        return ServiceResult.success(None)

    def _build_headers(self, request: GraphqlRequest) -> dict[str, str]:
        headers = {
            **dict(self._config.default_headers),
            **dict(request.headers),
        }

        if self._config.auth_provider is not None:
            headers.update(dict(self._config.auth_provider(request)))

        if self._config.user_agent is not None and "User-Agent" not in headers and "user-agent" not in headers:
            headers["User-Agent"] = self._config.user_agent

        return headers


def graphql_client(
    *,
    config: ServiceClientConfig,
    request: GraphqlRequest,
    decoder: GraphqlDecoder[T] | None = None,
) -> ServiceResult[GraphqlResponse[T]]:
    client = GraphqlClient(config)
    try:
        return client.execute(request, decoder=decoder)
    finally:
        client.close()


def _resolve_url(base_url: str, path: str) -> str:
    base = urllib.parse.urlsplit(base_url)
    path_segments = [segment for segment in base.path.split("/") if segment]
    path_segments.extend(segment for segment in path.lstrip("/").split("/") if segment)
    normalized_path = "/" + "/".join(path_segments)
    return urllib.parse.urlunsplit((base.scheme, base.netloc, normalized_path, "", ""))


def _encode_body(body: object | None, headers: dict[str, str]) -> bytes | None:
    if body is None:
        return None

    if "Content-Type" not in headers and "content-type" not in headers:
        headers["Content-Type"] = "application/json"

    return json.dumps(body).encode("utf-8")


def _headers_to_record(headers: Any) -> dict[str, str]:
    return {key.lower(): value for key, value in headers.items()}


def _decode_envelope(body: str, content_type: str | None) -> dict[str, object | None] | ServiceFailure:
    if body == "":
        return ServiceFailure(
            category=ServiceFailureCategory.GRAPHQL,
            code="invalid_graphql_response",
            message="The GraphQL response must be a JSON object envelope.",
            retryable=False,
            transport_id="graphql",
        )

    if not _looks_like_json(content_type, body):
        return ServiceFailure(
            category=ServiceFailureCategory.GRAPHQL,
            code="invalid_graphql_response",
            message="The GraphQL response must be a JSON object envelope.",
            retryable=False,
            transport_id="graphql",
        )

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

    if not isinstance(decoded, dict):
        return ServiceFailure(
            category=ServiceFailureCategory.GRAPHQL,
            code="invalid_graphql_response",
            message="The GraphQL response must be a JSON object envelope.",
            retryable=False,
            transport_id="graphql",
        )

    return cast(dict[str, object | None], decoded)


def _looks_like_json(content_type: str | None, body: str) -> bool:
    if content_type is not None:
        normalized = content_type.lower()
        if normalized == "application/json" or normalized.endswith("+json"):
            return True

    trimmed = body.lstrip()
    return trimmed.startswith("{") or trimmed.startswith("[")


def _decode_data(
    value: object | None,
    decoder: GraphqlDecoder[T] | None,
) -> T | None | ServiceFailure:
    if decoder is None:
        return cast(T | None, value)

    try:
        return decoder(value)
    except Exception as error:  # noqa: BLE001
        return ServiceFailure(
            category=ServiceFailureCategory.DECODE,
            code="invalid_graphql_data",
            message="The GraphQL response data could not be decoded.",
            retryable=False,
            transport_id="graphql",
            cause_summary=str(error),
        )


def _parse_errors(value: object | None) -> list[GraphqlError]:
    if not isinstance(value, list):
        return []

    errors: list[GraphqlError] = []
    for entry in value:
        error = entry if isinstance(entry, dict) else {}
        raw_locations = error.get("locations") if isinstance(error, dict) else None
        locations: list[GraphqlErrorLocation] = []
        if isinstance(raw_locations, list):
            for location in raw_locations:
                if isinstance(location, dict):
                    line = location.get("line")
                    column = location.get("column")
                    locations.append(
                        GraphqlErrorLocation(
                            line=line if isinstance(line, int) else 0,
                            column=column if isinstance(column, int) else 0,
                        )
                    )

        message = error.get("message", "Unknown GraphQL error") if isinstance(error, dict) else "Unknown GraphQL error"
        errors.append(
            GraphqlError(
                message=str(message),
                path=list(error.get("path", [])) if isinstance(error, dict) and isinstance(error.get("path"), list) else [],
                locations=locations,
                extensions=_parse_extensions(error.get("extensions")) if isinstance(error, dict) else None,
            )
        )

    return errors


def _parse_extensions(value: object | None) -> dict[str, object] | None:
    if not isinstance(value, dict):
        return None
    return {str(key): item for key, item in value.items()}


def _is_mutation_document(document: str) -> bool:
    return document.lstrip().startswith("mutation ")


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