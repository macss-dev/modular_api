import 'package:modular_api_rest_client/modular_api_rest_client.dart';

final class GraphqlLocation {
  const GraphqlLocation({required this.line, required this.column});

  final int line;
  final int column;
}

final class GraphqlError {
  const GraphqlError({
    required this.message,
    this.path = const [],
    this.locations = const [],
    this.extensions,
  });

  final String message;
  final List<Object?> path;
  final List<GraphqlLocation> locations;
  final Map<String, Object?>? extensions;
}

final class GraphqlResponse<T> {
  const GraphqlResponse({
    required this.data,
    required this.errors,
    required this.extensions,
    required this.metadata,
  });

  final T? data;
  final List<GraphqlError> errors;
  final Map<String, Object?>? extensions;
  final ServiceResponseMetadata metadata;
}

final class GraphqlRequest extends ServiceOperation {
  const GraphqlRequest({
    required super.operationId,
    required String document,
    super.variables,
    super.operationName,
    super.headers = const {},
    String path = '/graphql',
  }) : super(
         transportId: 'http',
         method: 'POST',
         path: path,
         document: document,
       );

  String get documentValue => document!;
}

final class GraphqlClient {
  GraphqlClient(this._config, {HttpServiceClient? httpClient})
    : _httpClient = httpClient ?? HttpServiceClient(_config),
      _ownsHttpClient = httpClient == null;

  final ServiceClientConfig _config;
  final HttpServiceClient _httpClient;
  final bool _ownsHttpClient;

  ServiceClientDescription describe() {
    return ServiceClientDescription(
      serviceId: _config.serviceId,
      transportId: 'graphql',
      baseUrl: _config.baseUrl,
      redactedSummary: _config.redactedSummary,
    );
  }

  Future<ServiceResult<GraphqlResponse<T>>> execute<T>(
    GraphqlRequest request, {
    ServiceDecoder<T>? decoder,
  }) async {
    if (_isMutationDocument(request.documentValue)) {
      return ServiceResult.failure(
        const ServiceFailure(
          category: ServiceFailureCategory.graphql,
          code: 'mutation_not_supported',
          message: 'GraphQL mutations are not supported in v1.',
          retryable: false,
          transportId: 'http',
        ),
      );
    }

    final transportResult = await _httpClient.execute<Object?>(
      ServiceRequest(
        operationId: request.operationId,
        method: 'POST',
        path: request.path!,
        headers: request.headers,
        body: {
          'query': request.documentValue,
          if (request.variables != null) 'variables': request.variables,
          if (request.operationName != null)
            'operationName': request.operationName,
        },
      ),
    );

    if (transportResult.isFailure) {
      return ServiceResult.failure(transportResult.failure);
    }

    final response = transportResult.value;
    final envelope = response.data;
    if (envelope is! Map<Object?, Object?>) {
      return ServiceResult.failure(
        const ServiceFailure(
          category: ServiceFailureCategory.graphql,
          code: 'invalid_graphql_response',
          message: 'The GraphQL response must be a JSON object envelope.',
          retryable: false,
          transportId: 'http',
        ),
      );
    }

    final errors = _parseErrors(envelope['errors']);
    final extensions = _parseExtensions(envelope['extensions']);
    final decodedData = _decodeData<T>(envelope['data'], decoder);
    if (decodedData case ServiceFailure failure) {
      return ServiceResult.failure(failure);
    }

    return ServiceResult.success(
      GraphqlResponse<T>(
        data: decodedData as T?,
        errors: errors,
        extensions: extensions,
        metadata: ServiceResponseMetadata(
          statusCode: response.metadata.statusCode,
          headers: response.metadata.headers,
          transportId: 'graphql',
          duration: response.metadata.duration,
          requestId: response.metadata.requestId,
        ),
      ),
    );
  }

  Future<ServiceResult<void>> close() async {
    if (_ownsHttpClient) {
      return _httpClient.close();
    }
    return ServiceResult.success(null);
  }
}

Future<ServiceResult<GraphqlResponse<T>>> graphqlClient<T>({
  required ServiceClientConfig config,
  required GraphqlRequest request,
  ServiceDecoder<T>? decoder,
}) async {
  final client = GraphqlClient(config);
  try {
    return await client.execute<T>(request, decoder: decoder);
  } finally {
    await client.close();
  }
}

bool _isMutationDocument(String document) {
  return RegExp(r'^\s*mutation\b').hasMatch(document);
}

List<GraphqlError> _parseErrors(Object? value) {
  if (value == null) {
    return const [];
  }
  if (value is! List) {
    return const [];
  }

  return value.map((item) {
    final error = item is Map<Object?, Object?> ? item : const <Object?, Object?>{};
    final locationsValue = error['locations'];
    return GraphqlError(
      message: error['message']?.toString() ?? 'Unknown GraphQL error',
      path: switch (error['path']) {
        List<dynamic> path => List<Object?>.from(path),
        _ => const [],
      },
      locations: locationsValue is List
          ? locationsValue
                .whereType<Map>()
                .map(
                  (location) => GraphqlLocation(
                    line: (location['line'] as num?)?.toInt() ?? 0,
                    column: (location['column'] as num?)?.toInt() ?? 0,
                  ),
                )
                .toList(growable: false)
          : const [],
      extensions: _parseExtensions(error['extensions']),
    );
  }).toList(growable: false);
}

Map<String, Object?>? _parseExtensions(Object? value) {
  return switch (value) {
    Map<Object?, Object?> map => {
      for (final entry in map.entries) entry.key.toString(): entry.value,
    },
    _ => null,
  };
}

Object? _decodeData<T>(Object? value, ServiceDecoder<T>? decoder) {
  if (decoder == null) {
    return value;
  }

  try {
    return decoder(value);
  } catch (error) {
    return ServiceFailure(
      category: ServiceFailureCategory.decode,
      code: 'invalid_graphql_data',
      message: 'The GraphQL response data could not be decoded.',
      retryable: false,
      transportId: 'http',
      causeSummary: '$error',
    );
  }
}