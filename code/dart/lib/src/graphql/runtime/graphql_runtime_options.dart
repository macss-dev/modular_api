import 'dart:async';

import 'package:modular_api/src/graphql/catalog/graphql_catalog_builder.dart';
import 'package:modular_api/src/graphql/read/sql_read_contract.dart';
import 'package:modular_api/src/graphql/schema/graphql_schema_sdl_generator.dart';

typedef GraphqlCatalogFactory = FutureOr<GraphqlCatalog> Function();
typedef GraphqlSdlFactory = String Function(GraphqlCatalog catalog);
typedef GraphqlEventSink = FutureOr<void> Function(GraphqlRequestEvent event);

const graphqlDefaultSqlReadExecutorCapabilityId = 'modular_api.sql.read_executor';

enum GraphqlRequestPhase {
  started,
  completed,
}

final class GraphqlRequestEvent {
  const GraphqlRequestEvent({
    required this.phase,
    required this.requestId,
    required this.method,
    required this.path,
    this.statusCode,
  });

  final GraphqlRequestPhase phase;
  final String requestId;
  final String method;
  final String path;
  final int? statusCode;
}

final class GraphqlOptions {
  GraphqlOptions({
    required this.catalogFactory,
    this.executor,
    this.executionCapabilityId,
    this.introspectionEnabled = false,
    this.maxDepth = 8,
    this.maxComplexity = 500,
    this.defaultLimit = 50,
    this.maxLimit = 200,
    this.onEvent,
    GraphqlSdlFactory? sdlFactory,
  }) : sdlFactory = sdlFactory ?? const GraphqlSchemaSdlGenerator().generate {
    if (executor != null && executionCapabilityId != null) {
      throw ArgumentError(
        'GraphQL runtime accepts either a direct executor or an execution capability id, not both.',
      );
    }
  }

  final GraphqlCatalogFactory catalogFactory;
  final SqlReadExecutor? executor;
  final String? executionCapabilityId;
  final bool introspectionEnabled;
  final int maxDepth;
  final int maxComplexity;
  final int defaultLimit;
  final int maxLimit;
  final GraphqlEventSink? onEvent;
  final GraphqlSdlFactory sdlFactory;

  String get resolvedExecutionCapabilityId =>
      executionCapabilityId ?? graphqlDefaultSqlReadExecutorCapabilityId;
}