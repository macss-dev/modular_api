"""Public package exports for modular_api_rest_client."""

from .client import (
	HttpServiceClient,
	ServiceClientConfig,
	ServiceClientDescription,
	ServiceFailure,
	ServiceFailureCategory,
	ServiceOperation,
	ServiceRequest,
	ServiceResponse,
	ServiceResponseMetadata,
	ServiceResult,
	ServiceRetryPolicy,
	ServiceTelemetryHooks,
	http_client,
)

__all__ = [
	"HttpServiceClient",
	"ServiceClientConfig",
	"ServiceClientDescription",
	"ServiceFailure",
	"ServiceFailureCategory",
	"ServiceOperation",
	"ServiceRequest",
	"ServiceResponse",
	"ServiceResponseMetadata",
	"ServiceResult",
	"ServiceRetryPolicy",
	"ServiceTelemetryHooks",
	"http_client",
]