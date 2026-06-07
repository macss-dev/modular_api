import 'dart:async';
import 'dart:convert';
import 'dart:io';

typedef ServiceDecoder<T> = T Function(Object? value);
typedef ServiceAuthProvider = FutureOr<Map<String, String>> Function(
  ServiceOperation operation,
);

class ServiceClientConfig {
  const ServiceClientConfig({
    required this.serviceId,
    required this.baseUrl,
    required this.redactedSummary,
    this.defaultHeaders = const {},
    this.authProvider,
    this.timeout,
    this.retryPolicy,
    this.userAgent,
    this.telemetryHooks,
  });

  final String serviceId;
  final Uri baseUrl;
  final String redactedSummary;
  final Map<String, String> defaultHeaders;
  final ServiceAuthProvider? authProvider;
  final Duration? timeout;
  final ServiceRetryPolicy? retryPolicy;
  final String? userAgent;
  final ServiceTelemetryHooks? telemetryHooks;
}

class ServiceRetryPolicy {
  const ServiceRetryPolicy({this.maxAttempts = 1});

  final int maxAttempts;
}

class ServiceTelemetryHooks {
  const ServiceTelemetryHooks({
    this.onStarted,
    this.onCompleted,
  });

  final void Function(ServiceOperation operation)? onStarted;
  final void Function(ServiceOperation operation, ServiceResult<Object?> result)?
      onCompleted;
}

class ServiceOperation {
  const ServiceOperation({
    required this.transportId,
    required this.operationId,
    this.headers = const {},
    this.method,
    this.path,
    this.query,
    this.body,
    this.document,
    this.variables,
    this.operationName,
  });

  final String transportId;
  final String operationId;
  final Map<String, String> headers;
  final String? method;
  final String? path;
  final Map<String, Object?>? query;
  final Object? body;
  final String? document;
  final Map<String, Object?>? variables;
  final String? operationName;
}

class ServiceRequest extends ServiceOperation {
  const ServiceRequest({
    required super.operationId,
    required String method,
    required String path,
    super.headers = const {},
    super.query,
    super.body,
  }) : super(
         transportId: 'http',
         method: method,
         path: path,
       );
}

class ServiceResponseMetadata {
  const ServiceResponseMetadata({
    required this.statusCode,
    required this.headers,
    required this.transportId,
    required this.duration,
    this.requestId,
  });

  final int statusCode;
  final Map<String, String> headers;
  final String transportId;
  final Duration duration;
  final String? requestId;
}

class ServiceResponse<T> {
  const ServiceResponse({required this.data, required this.metadata});

  final T data;
  final ServiceResponseMetadata metadata;
}

enum ServiceFailureCategory {
  transport,
  timeout,
  auth,
  rateLimit,
  protocol,
  decode,
  graphql,
  unexpected,
}

class ServiceFailure {
  const ServiceFailure({
    required this.category,
    required this.code,
    required this.message,
    required this.retryable,
    this.statusCode,
    this.transportId,
    this.details,
    this.causeSummary,
  });

  final ServiceFailureCategory category;
  final String code;
  final String message;
  final bool retryable;
  final int? statusCode;
  final String? transportId;
  final Object? details;
  final String? causeSummary;
}

class ServiceResult<T> {
  const ServiceResult._(this._value, this._failure);

  factory ServiceResult.success(T value) {
    return ServiceResult._(value, null);
  }

  factory ServiceResult.failure(ServiceFailure failure) {
    return ServiceResult._(null, failure);
  }

  final T? _value;
  final ServiceFailure? _failure;

  bool get isSuccess => _failure == null;
  bool get isFailure => _failure != null;

  T get value {
    if (_value case final value?) {
      return value;
    }
    throw StateError('ServiceResult does not contain a success value.');
  }

  ServiceFailure get failure {
    if (_failure case final failure?) {
      return failure;
    }
    throw StateError('ServiceResult does not contain a failure value.');
  }
}

class ServiceClientDescription {
  const ServiceClientDescription({
    required this.serviceId,
    required this.transportId,
    required this.baseUrl,
    required this.redactedSummary,
  });

  final String serviceId;
  final String transportId;
  final Uri baseUrl;
  final String redactedSummary;
}

abstract class ServiceClient {
  Future<ServiceResult<ServiceResponse<T>>> execute<T>(
    ServiceOperation operation, {
    ServiceDecoder<T>? decoder,
  });

  Future<ServiceResult<void>> close();

  ServiceClientDescription describe();
}

class HttpServiceClient implements ServiceClient {
  HttpServiceClient(this.config, {HttpClient? httpClient})
    : _httpClient = httpClient ?? HttpClient(),
      _ownsHttpClient = httpClient == null {
    if (config.timeout case final timeout?) {
      _httpClient.connectionTimeout = timeout;
    }
    if (config.userAgent case final userAgent?) {
      _httpClient.userAgent = userAgent;
    }
  }

  final ServiceClientConfig config;
  final HttpClient _httpClient;
  final bool _ownsHttpClient;
  bool _closed = false;

  @override
  ServiceClientDescription describe() {
    return ServiceClientDescription(
      serviceId: config.serviceId,
      transportId: 'http',
      baseUrl: config.baseUrl,
      redactedSummary: config.redactedSummary,
    );
  }

  @override
  Future<ServiceResult<ServiceResponse<T>>> execute<T>(
    ServiceOperation operation, {
    ServiceDecoder<T>? decoder,
  }) async {
    if (_closed) {
      return ServiceResult.failure(
        const ServiceFailure(
          category: ServiceFailureCategory.unexpected,
          code: 'client_closed',
          message: 'The HTTP service client is already closed.',
          retryable: false,
          transportId: 'http',
        ),
      );
    }

    final method = operation.method;
    final path = operation.path;
    if (operation.transportId != 'http' || method == null || path == null) {
      return ServiceResult.failure(
        const ServiceFailure(
          category: ServiceFailureCategory.protocol,
          code: 'invalid_operation',
          message: 'HTTP execution requires transportId, method, and path.',
          retryable: false,
          transportId: 'http',
        ),
      );
    }

    config.telemetryHooks?.onStarted?.call(operation);

    final stopwatch = Stopwatch()..start();
    final uri = _resolveUri(config.baseUrl, path, operation.query);
    final headers = <String, String>{...config.defaultHeaders, ...operation.headers};

    if (config.authProvider case final authProvider?) {
      headers.addAll(await authProvider(operation));
    }

    final responseResult = await _withTimeout(
      _executeRequest<T>(
        operation: operation,
        method: method,
        uri: uri,
        headers: headers,
        decoder: decoder,
        stopwatch: stopwatch,
      ),
      operation: operation,
    );

    config.telemetryHooks?.onCompleted?.call(
      operation,
      responseResult.isSuccess
          ? ServiceResult<Object?>.success(responseResult.value)
          : ServiceResult.failure(responseResult.failure),
    );

    return responseResult;
  }

  @override
  Future<ServiceResult<void>> close() async {
    if (_closed) {
      return ServiceResult.success(null);
    }

    _closed = true;
    if (_ownsHttpClient) {
      _httpClient.close(force: true);
    }

    return ServiceResult.success(null);
  }

  Future<ServiceResult<ServiceResponse<T>>> _executeRequest<T>({
    required ServiceOperation operation,
    required String method,
    required Uri uri,
    required Map<String, String> headers,
    required ServiceDecoder<T>? decoder,
    required Stopwatch stopwatch,
  }) async {
    try {
      final request = await _httpClient.openUrl(method, uri);
      for (final entry in headers.entries) {
        request.headers.set(entry.key, entry.value);
      }

      if (operation.body != null) {
        request.headers.contentType ??= ContentType.json;
        request.write(jsonEncode(operation.body));
      }

      final response = await request.close();
      final body = await utf8.decoder.bind(response).join();
      stopwatch.stop();

      final responseHeaders = _flattenHeaders(response.headers);
      final requestId = responseHeaders['x-request-id'];
      if (!_isSuccessStatusCode(response.statusCode)) {
        return ServiceResult.failure(
          ServiceFailure(
            category: _categoryForStatus(response.statusCode),
            code: _codeForStatus(response.statusCode),
            message: body.isEmpty
                ? 'HTTP request failed with status ${response.statusCode}.'
                : body,
            retryable: _isRetryableStatus(response.statusCode),
            statusCode: response.statusCode,
            transportId: 'http',
            details: body.isEmpty ? null : body,
          ),
        );
      }

      final decoded = _decodeBody<T>(
        body: body,
        contentType: response.headers.contentType,
        decoder: decoder,
      );
      if (decoded case ServiceFailure failure) {
        return ServiceResult.failure(failure);
      }

      return ServiceResult.success(
        ServiceResponse<T>(
          data: decoded as T,
          metadata: ServiceResponseMetadata(
            statusCode: response.statusCode,
            headers: responseHeaders,
            transportId: 'http',
            duration: stopwatch.elapsed,
            requestId: requestId,
          ),
        ),
      );
    } on TimeoutException catch (error) {
      return ServiceResult.failure(
        ServiceFailure(
          category: ServiceFailureCategory.timeout,
          code: 'timeout',
          message: 'The HTTP request timed out.',
          retryable: true,
          transportId: 'http',
          causeSummary: error.message,
        ),
      );
    } on SocketException catch (error) {
      return ServiceResult.failure(
        ServiceFailure(
          category: ServiceFailureCategory.transport,
          code: 'transport_error',
          message: 'The HTTP request failed to reach the remote service.',
          retryable: true,
          transportId: 'http',
          causeSummary: error.message,
        ),
      );
    } on HttpException catch (error) {
      return ServiceResult.failure(
        ServiceFailure(
          category: ServiceFailureCategory.transport,
          code: 'http_exception',
          message: error.message,
          retryable: true,
          transportId: 'http',
        ),
      );
    } on FormatException catch (error) {
      return ServiceResult.failure(
        ServiceFailure(
          category: ServiceFailureCategory.decode,
          code: 'invalid_json',
          message: 'The HTTP response body is not valid JSON.',
          retryable: false,
          transportId: 'http',
          causeSummary: error.message,
        ),
      );
    } catch (error) {
      return ServiceResult.failure(
        ServiceFailure(
          category: ServiceFailureCategory.unexpected,
          code: 'unexpected_error',
          message: 'The HTTP request failed unexpectedly.',
          retryable: false,
          transportId: 'http',
          causeSummary: '$error',
        ),
      );
    }
  }

  Future<ServiceResult<ServiceResponse<T>>> _withTimeout<T>(
    Future<ServiceResult<ServiceResponse<T>>> future, {
    required ServiceOperation operation,
  }) async {
    final timeout = config.timeout;
    if (timeout == null) {
      return future;
    }

    return future.timeout(
      timeout,
      onTimeout: () => ServiceResult.failure(
        const ServiceFailure(
          category: ServiceFailureCategory.timeout,
          code: 'timeout',
          message: 'The HTTP request timed out.',
          retryable: true,
          transportId: 'http',
        ),
      ),
    );
  }
}

Future<ServiceResult<ServiceResponse<T>>> httpClient<T>({
  required ServiceClientConfig config,
  required ServiceRequest request,
  ServiceDecoder<T>? decoder,
}) async {
  final client = HttpServiceClient(config);
  try {
    return await client.execute<T>(request, decoder: decoder);
  } finally {
    await client.close();
  }
}

Uri _resolveUri(
  Uri baseUrl,
  String path,
  Map<String, Object?>? query,
) {
  final normalizedPath = path.startsWith('/') ? path.substring(1) : path;
  final pathSegments = [
    ...baseUrl.pathSegments.where((segment) => segment.isNotEmpty),
    ...normalizedPath.split('/').where((segment) => segment.isNotEmpty),
  ];

  return baseUrl.replace(
    pathSegments: pathSegments,
    queryParameters: query == null
        ? null
        : {
            for (final entry in query.entries)
              entry.key: entry.value?.toString(),
          },
  );
}

Map<String, String> _flattenHeaders(HttpHeaders headers) {
  final result = <String, String>{};
  headers.forEach((name, values) {
    result[name] = values.join(',');
  });
  return result;
}

bool _isSuccessStatusCode(int statusCode) {
  return statusCode >= 200 && statusCode < 300;
}

bool _isRetryableStatus(int statusCode) {
  return statusCode == HttpStatus.tooManyRequests || statusCode >= 500;
}

ServiceFailureCategory _categoryForStatus(int statusCode) {
  if (statusCode == HttpStatus.unauthorized ||
      statusCode == HttpStatus.forbidden) {
    return ServiceFailureCategory.auth;
  }
  if (statusCode == HttpStatus.tooManyRequests) {
    return ServiceFailureCategory.rateLimit;
  }
  return ServiceFailureCategory.protocol;
}

String _codeForStatus(int statusCode) {
  if (statusCode == HttpStatus.unauthorized) {
    return 'unauthorized';
  }
  if (statusCode == HttpStatus.forbidden) {
    return 'forbidden';
  }
  if (statusCode == HttpStatus.tooManyRequests) {
    return 'rate_limit';
  }
  return 'http_$statusCode';
}

Object? _decodeBody<T>({
  required String body,
  required ContentType? contentType,
  required ServiceDecoder<T>? decoder,
}) {
  final decodedBody = body.isEmpty
      ? null
      : _looksLikeJson(contentType, body)
      ? jsonDecode(body)
      : body;

  if (decoder != null) {
    return decoder(decodedBody);
  }

  return decodedBody as T;
}

bool _looksLikeJson(ContentType? contentType, String body) {
  final mimeType = contentType?.mimeType.toLowerCase();
  if (mimeType == 'application/json' || mimeType?.endsWith('+json') == true) {
    return true;
  }

  final trimmed = body.trimLeft();
  return trimmed.startsWith('{') || trimmed.startsWith('[');
}