import 'dart:convert';

import 'package:modular_api/src/core/health/health_service.dart';
import 'package:modular_api/src/core/metrics/metric.dart';
import 'package:modular_api/src/core/metrics/metric_registry.dart';
import 'package:modular_api/src/core/metrics/metrics_middleware.dart';
import 'package:modular_api/src/core/plugin.dart';
import 'package:modular_api/src/graphql/runtime/graphql_runtime_health.dart';
import 'package:modular_api/src/graphql/runtime/graphql_runtime_options.dart';
import 'package:modular_api/src/graphql/runtime/graphql_runtime_plugin.dart';
import 'package:modular_api/src/openapi/openapi.dart';
import 'package:modular_api/src/openapi/swagger_docs.dart';
import 'package:shelf/shelf.dart';

const _openApiSpecCapabilityId = 'modular_api.openapi.spec';
const _officialPluginHostRange = '>=0.1.0 <0.2.0';

class OperationalRoutePaths {
  final String healthPath;
  final String docsPath;
  final String openApiJsonPath;
  final String openApiYamlPath;
  final String? metricsPath;

  const OperationalRoutePaths({
    required this.healthPath,
    required this.docsPath,
    required this.openApiJsonPath,
    required this.openApiYamlPath,
    this.metricsPath,
  });
}

OperationalRoutePaths operationalRoutePaths({
  required String basePath,
  String? metricsPath,
}) {
  return OperationalRoutePaths(
    healthPath: _joinPath(basePath, '/health'),
    docsPath: _joinPath(basePath, '/docs'),
    openApiJsonPath: _joinPath(basePath, '/openapi.json'),
    openApiYamlPath: _joinPath(basePath, '/openapi.yaml'),
    metricsPath: metricsPath == null ? null : _joinPath(basePath, metricsPath),
  );
}

Future<List<Plugin>> buildRuntimePlugins({
  required String basePath,
  required String title,
  required int port,
  required HealthService healthService,
  required List<String> registeredPaths,
  List<Map<String, String>>? servers,
  MetricRegistry? metricRegistry,
  Counter? requestsTotal,
  Gauge? requestsInFlight,
  Histogram? requestDuration,
  String? metricsPath,
  List<String> excludedMetricsRoutes = const [],
  GraphqlOptions? graphql,
  required GraphqlRuntimeState graphqlRuntimeState,
}) async {
  final plugins = <Plugin>[
    _HealthRuntimePlugin(healthService: healthService),
  ];

  if (graphql != null) {
    plugins.add(
      await buildGraphqlRuntimePlugin(
        options: graphql,
        runtimeState: graphqlRuntimeState,
      ),
    );
  }

  if (metricRegistry != null &&
      requestsTotal != null &&
      requestsInFlight != null &&
      requestDuration != null &&
      metricsPath != null) {
    plugins.add(
      _MetricsRuntimePlugin(
        basePath: basePath,
        metricsPath: metricsPath,
        registry: metricRegistry,
        requestsTotal: requestsTotal,
        requestsInFlight: requestsInFlight,
        requestDuration: requestDuration,
        registeredPaths: registeredPaths,
        excludedRoutes: excludedMetricsRoutes,
      ),
    );
  }

  final openApiJson = await OpenApi.jsonStringFromSchema(
    title: title,
    port: port,
    servers: servers,
  );
  final openApiYaml = OpenApi.jsonToYaml(jsonDecode(openApiJson));

  plugins.add(
    _OpenApiRuntimePlugin(
      basePath: basePath,
      jsonSpec: openApiJson,
      yamlSpec: openApiYaml,
    ),
  );
  plugins.add(const _DocsRuntimePlugin());

  return plugins;
}

class _HealthRuntimePlugin implements Plugin {
  final HealthService healthService;

  const _HealthRuntimePlugin({required this.healthService});

  @override
  PluginManifest get manifest => const PluginManifest(
        id: 'modular_api.health',
        displayName: 'Health Plugin',
        version: '0.1.0',
        hostApiVersion: _officialPluginHostRange,
      );

  @override
  void setup(PluginHost host) {
    host.registerRoute(
      PluginRoute(
        id: 'health.endpoint',
        method: 'GET',
        path: '/health',
        visibility: 'operational',
        handler: (context) async {
          final health = await healthService.evaluate();
          return Response(
            health.httpStatusCode,
            body: jsonEncode(health.toJson()),
            headers: {'content-type': 'application/health+json; charset=utf-8'},
          );
        },
      ),
    );
  }
}

class _MetricsRuntimePlugin implements Plugin {
  final String basePath;
  final String metricsPath;
  final MetricRegistry registry;
  final Counter requestsTotal;
  final Gauge requestsInFlight;
  final Histogram requestDuration;
  final List<String> registeredPaths;
  final List<String> excludedRoutes;

  const _MetricsRuntimePlugin({
    required this.basePath,
    required this.metricsPath,
    required this.registry,
    required this.requestsTotal,
    required this.requestsInFlight,
    required this.requestDuration,
    required this.registeredPaths,
    required this.excludedRoutes,
  });

  @override
  PluginManifest get manifest => const PluginManifest(
        id: 'modular_api.metrics',
        displayName: 'Metrics Plugin',
        version: '0.1.0',
        hostApiVersion: _officialPluginHostRange,
      );

  @override
  void setup(PluginHost host) {
    final paths = operationalRoutePaths(basePath: basePath, metricsPath: metricsPath);
    final allExcludedRoutes = <String>{
      ...excludedRoutes.map((route) => _joinPath(basePath, route)),
      paths.healthPath,
      paths.docsPath,
      paths.openApiJsonPath,
      paths.openApiYamlPath,
      if (paths.metricsPath != null) paths.metricsPath!,
    };

    host.registerMiddleware(
      PluginMiddleware(
        id: 'metrics.middleware',
        slot: 'preRouting',
        handler: metricsMiddleware(
          requestsTotal: requestsTotal,
          requestsInFlight: requestsInFlight,
          requestDuration: requestDuration,
          excludedRoutes: allExcludedRoutes.toList(),
          registeredPaths: registeredPaths,
        ),
      ),
    );

    host.registerRoute(
      PluginRoute(
        id: 'metrics.endpoint',
        method: 'GET',
        path: metricsPath,
        visibility: 'operational',
        handler: (context) => Response.ok(
          registry.serialize(),
          headers: {'content-type': 'text/plain; version=0.0.4; charset=utf-8'},
        ),
      ),
    );
  }
}

class _OpenApiRuntimePlugin implements Plugin {
  final String basePath;
  final String jsonSpec;
  final String yamlSpec;

  const _OpenApiRuntimePlugin({
    required this.basePath,
    required this.jsonSpec,
    required this.yamlSpec,
  });

  @override
  PluginManifest get manifest => const PluginManifest(
        id: 'modular_api.openapi',
        displayName: 'OpenAPI Plugin',
        version: '0.1.0',
        hostApiVersion: _officialPluginHostRange,
      );

  @override
  void setup(PluginHost host) {
    final paths = operationalRoutePaths(basePath: basePath);
    host.exposeCapability(
      Capability<_OpenApiCapability>(
        id: _openApiSpecCapabilityId,
        version: '1.0.0',
        value: _OpenApiCapability(
          specUrl: paths.openApiJsonPath,
          jsonSpec: jsonSpec,
          yamlSpec: yamlSpec,
        ),
      ),
    );

    host.registerRoute(
      PluginRoute(
        id: 'openapi.json.endpoint',
        method: 'GET',
        path: '/openapi.json',
        visibility: 'operational',
        handler: (context) => Response.ok(
          jsonSpec,
          headers: {'content-type': 'application/json; charset=utf-8'},
        ),
      ),
    );
    host.registerRoute(
      PluginRoute(
        id: 'openapi.yaml.endpoint',
        method: 'GET',
        path: '/openapi.yaml',
        visibility: 'operational',
        handler: (context) => Response.ok(
          yamlSpec,
          headers: {'content-type': 'application/x-yaml; charset=utf-8'},
        ),
      ),
    );
  }
}

class _DocsRuntimePlugin implements Plugin {
  const _DocsRuntimePlugin();

  @override
  PluginManifest get manifest => const PluginManifest(
        id: 'modular_api.docs',
        displayName: 'Docs Plugin',
        version: '0.1.0',
        hostApiVersion: _officialPluginHostRange,
      );

  @override
  void setup(PluginHost host) {
    final capability = host.requireCapability(_openApiSpecCapabilityId);
    final openApiSpec = capability.value as _OpenApiCapability;
    final html = buildSwaggerDocsHtml(
      title: host.metadata().title,
      specUrl: openApiSpec.specUrl,
    );

    host.registerRoute(
      PluginRoute(
        id: 'docs.endpoint',
        method: 'GET',
        path: '/docs',
        visibility: 'operational',
        handler: (context) => Response.ok(
          html,
          headers: {'content-type': 'text/html; charset=utf-8'},
        ),
      ),
    );
  }
}

class _OpenApiCapability {
  final String specUrl;
  final String jsonSpec;
  final String yamlSpec;

  const _OpenApiCapability({
    required this.specUrl,
    required this.jsonSpec,
    required this.yamlSpec,
  });
}

String _normalizeBasePath(String basePath) {
  if (basePath.isEmpty || basePath == '/') {
    return '/';
  }

  return '/${basePath.trim().replaceAll(RegExp(r'^/+|/+$'), '')}';
}

String _normalizeRelativePath(String path) {
  final trimmed = path.trim();
  if (trimmed.isEmpty) {
    throw ArgumentError.value(path, 'path', 'Plugin route path cannot be empty');
  }

  return '/${trimmed.replaceAll(RegExp(r'^/+|/+$'), '')}';
}

String _joinPath(String basePath, String relativePath) {
  final normalizedBasePath = _normalizeBasePath(basePath);
  final normalizedRelativePath = _normalizeRelativePath(relativePath);

  if (normalizedBasePath == '/') {
    return normalizedRelativePath;
  }

  return '$normalizedBasePath$normalizedRelativePath'.replaceAll(RegExp(r'/+'), '/');
}