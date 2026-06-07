import 'dart:io';
import 'package:modular_api/modular_api.dart';
import 'package:modular_api/src/core/error_response_middleware.dart';
import 'package:modular_api/src/graphql/runtime/graphql_runtime_health.dart';
import 'package:modular_api/src/core/logger/logging_middleware.dart';
import 'package:modular_api/src/core/metrics/metric_registry.dart';
import 'package:modular_api/src/core/official_plugins.dart';
import 'package:modular_api/src/core/usecase/usecase_http_handler.dart';
import 'package:shelf/shelf.dart';
import 'package:shelf/shelf_io.dart' as shelf_io;
import 'package:shelf_router/shelf_router.dart';

final apiRegistry = _ApiRegistry();

typedef UseCaseFactory = UseCase Function(Map<String, dynamic> json);

class ModularApi {
  final Router _root = Router();
  final List<Middleware> _middlewares = [];
  final List<Plugin> _plugins = [];
  final String basePath;
  final String title;
  final String version;
  final HealthService _healthService;
  final GraphqlOptions? graphql;
  final GraphqlRuntimeState _graphqlRuntimeState = GraphqlRuntimeState.disabled();

  // ── Logger ──
  final LogLevel logLevel;

  // ── OpenAPI ──
  final List<Map<String, String>>? servers;

  // ── Metrics ──
  final bool metricsEnabled;
  final String metricsPath;
  final List<String> _excludedMetricsRoutes;
  MetricRegistry? _metricRegistry;
  MetricsRegistrar? _metricsRegistrar;

  // Built-in metrics (initialised lazily when metricsEnabled).
  Counter? _httpRequestsTotal;
  Gauge? _httpRequestsInFlight;
  Histogram? _httpRequestDuration;

  /// Public accessor for custom-metric registration.
  /// Returns `null` when metrics are disabled.
  MetricsRegistrar? get metrics => _metricsRegistrar;

  /// Creates a new ModularApi instance.
  ///
  /// [version] — API version (e.g. '1.0.0'). Used in health check response.
  /// [releaseId] — Defaults to `version-debug`. Override at compile time:
  ///   `dart compile exe --define=RELEASE_ID=1.2.3 bin/main.dart`
  /// [servers] — OpenAPI `servers` list. Each entry is a map with `url` and
  /// optional `description`. When omitted, `serve()` generates
  /// `[{url: 'http://localhost:{port}'}]` automatically.
  /// [metricsEnabled] — Opt-in Prometheus metrics at [metricsPath].
  /// [metricsPath] — Path for the metrics endpoint (default `/metrics`).
  /// [excludedMetricsRoutes] — Routes excluded from instrumentation.
  /// [logLevel] — Minimum RFC 5424 severity to emit (default `LogLevel.info`).
  ModularApi({
    this.basePath = '/api',
    this.title = 'Modular API',
    this.version = 'x.y.z',
    this.graphql,
    String? releaseId,
    this.servers,
    this.metricsEnabled = false,
    this.metricsPath = '/metrics',
    List<String>? excludedMetricsRoutes,
    this.logLevel = LogLevel.info,
  })  : _healthService = HealthService(
          version: version,
          releaseId: releaseId,
        ),
        _excludedMetricsRoutes = excludedMetricsRoutes ??
            ['/metrics', '/health', '/docs', '/docs/'] {
      _healthService.addHealthCheck(GraphqlRuntimeHealthCheck(_graphqlRuntimeState));

    if (metricsEnabled) {
      _metricRegistry = MetricRegistry();
      _metricsRegistrar = MetricsRegistrar(_metricRegistry!);
      _httpRequestsTotal = _metricRegistry!.createCounter(
        name: 'http_requests_total',
        help: 'Total number of HTTP requests.',
      );
      _httpRequestsInFlight = _metricRegistry!.createGauge(
        name: 'http_requests_in_flight',
        help: 'Number of HTTP requests currently being processed.',
      );
      _httpRequestDuration = _metricRegistry!.createHistogram(
        name: 'http_request_duration_seconds',
        help: 'HTTP request duration in seconds.',
      );
    }
  }

  /// Register a [HealthCheck] to be evaluated on `GET /health`.
  ///
  /// ```dart
  /// api.addHealthCheck(DatabaseHealthCheck());
  /// ```
  ModularApi addHealthCheck(HealthCheck check) {
    _healthService.addHealthCheck(check);
    return this;
  }

  ModularApi module(String name, void Function(ModuleBuilder) build) {
    final m = ModuleBuilder(
      basePath: basePath,
      moduleName: name,
      root: _root,
    );

    build(m);
    m._mount();

    return this;
  }

  ModularApi use(Middleware middleware) {
    _middlewares.add(middleware);
    return this;
  }

  ModularApi plugin(Plugin plugin) {
    _plugins.add(plugin);
    return this;
  }

  Future<HttpServer> serve({
    InternetAddress? ip,
    required int port,
    Future<void> Function(Router root)? onBeforeServe,
  }) async {
    _graphqlRuntimeState.markDisabled();

    final operationalPaths = operationalRoutePaths(
      basePath: basePath,
      metricsPath: metricsEnabled ? metricsPath : null,
    );
    final runtimePlugins = [
      ..._plugins,
      ...await buildRuntimePlugins(
        basePath: basePath,
        title: title,
        port: port,
        healthService: _healthService,
        registeredPaths: apiRegistry.routes.map((route) => route.path).toList(),
        servers: servers,
        metricRegistry: _metricRegistry,
        requestsTotal: _httpRequestsTotal,
        requestsInFlight: _httpRequestsInFlight,
        requestDuration: _httpRequestDuration,
        metricsPath: metricsEnabled ? metricsPath : null,
        excludedMetricsRoutes: _excludedMetricsRoutes,
        graphql: graphql,
        graphqlRuntimeState: _graphqlRuntimeState,
      ),
    ];

    final seenPluginIds = <String>{};
    for (final plugin in runtimePlugins) {
      if (!seenPluginIds.add(plugin.manifest.id)) {
        throw PluginHostError(
          'PLUGIN_ID_CONFLICT',
          'Duplicate plugin id: ${plugin.manifest.id}',
          resourceId: plugin.manifest.id,
        );
      }
    }

    final orderedPlugins = orderPlugins(runtimePlugins);

    final pluginHost = RuntimePluginHost(
      basePath: basePath,
      title: title,
      version: version,
    );

    try {
      for (final plugin in orderedPlugins) {
        pluginHost.beginPluginSetup(plugin.manifest.id);
        try {
          plugin.setup(pluginHost);
        } finally {
          pluginHost.endPluginSetup();
        }
        if (plugin is ShutdownAwarePlugin) {
          final shutdownAwarePlugin = plugin as ShutdownAwarePlugin;
          pluginHost.onShutdown(() => shutdownAwarePlugin.shutdown());
        }
      }

      pluginHost.freeze();
      final validationResults = <PluginValidationResult>[];
      for (final plugin in orderedPlugins) {
        if (plugin is ValidatingPlugin) {
          final validatingPlugin = plugin as ValidatingPlugin;
          validationResults.addAll(validatingPlugin.validate(pluginHost));
        }
      }
      pluginHost.assertValid(validationResults);
    } catch (_) {
      await pluginHost.shutdown();
      rethrow;
    }

    pluginHost.applyRoutes(_root);

    if (onBeforeServe != null) {
      await onBeforeServe(_root);
    }

    var pipeline = const Pipeline();

    // Logging middleware FIRST (outermost) to capture full lifecycle
    // including all subsequent middlewares.
    pipeline = pipeline.addMiddleware(
      loggingMiddleware(
        logLevel: logLevel,
        serviceName: title,
        excludedRoutes: [
          operationalPaths.healthPath,
          operationalPaths.docsPath,
          operationalPaths.openApiJsonPath,
          operationalPaths.openApiYamlPath,
          if (operationalPaths.metricsPath != null) operationalPaths.metricsPath!,
        ],
      ),
    );
    pipeline = pipeline.addMiddleware(errorResponseMiddleware());

    for (final middleware in pluginHost.middlewaresForSlot('preRouting')) {
      pipeline = pipeline.addMiddleware(middleware.handler);
    }

    for (final m in _middlewares) {
      pipeline = pipeline.addMiddleware(m);
    }

    for (final middleware in pluginHost.middlewaresForSlot('preHandler')) {
      pipeline = pipeline.addMiddleware(middleware.handler);
    }

    for (final middleware in pluginHost.middlewaresForSlot('postHandler')) {
      pipeline = pipeline.addMiddleware(middleware.handler);
    }

    final handler = pipeline.addHandler(_root.call);
    final server = await shelf_io.serve(
      handler,
      ip ?? InternetAddress.anyIPv4,
      port,
    );
    final managedServer = _ManagedHttpServer(server, pluginHost.shutdown);

    /// Print info
    stdout.writeln('Docs on http://localhost:${managedServer.port}${operationalPaths.docsPath}');
    stdout.writeln('Health on http://localhost:${managedServer.port}${operationalPaths.healthPath}');
    stdout.writeln('OpenAPI JSON on http://localhost:${managedServer.port}${operationalPaths.openApiJsonPath}');
    stdout.writeln('OpenAPI YAML on http://localhost:${managedServer.port}${operationalPaths.openApiYamlPath}');
    if (operationalPaths.metricsPath != null) {
      stdout.writeln('Metrics on http://localhost:${managedServer.port}${operationalPaths.metricsPath}');
    }

    /// Return server
    return managedServer;
  }
}

class _ManagedHttpServer implements HttpServer {
  final HttpServer _delegate;
  final Future<void> Function() _onClose;
  bool _closed = false;

  _ManagedHttpServer(this._delegate, this._onClose);

  @override
  int get port => _delegate.port;

  @override
  Future<HttpServer> close({bool force = false}) async {
    await _delegate.close(force: force);
    if (!_closed) {
      _closed = true;
      await _onClose();
    }
    return this;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class ModuleBuilder {
  final String basePath;
  final String moduleName;
  final Router _root;
  final Router _module = Router();

  ModuleBuilder({
    required this.basePath,
    required this.moduleName,
    required Router root,
  }) : _root = root;

  /// Registers a use case as an HTTP endpoint on this module.
  ///
  /// [command] becomes the route segment and the OpenAPI operationId root.
  /// Convention: command, class name, and file name share the same root.
  /// Example: command `'hello-world'` → class `HelloWorld` → file `hello_world.dart`.
  ModuleBuilder usecase(
    String command,
    UseCaseFactory usecaseFactory, {
    String method = 'POST',
    String? summary,
    String? description,
    required Input inputExample,
    required Output outputExample,
  }) {
    Handler h = useCaseHttpHandler(usecaseFactory, inputExample: inputExample);

    command = command.trim();
    if (command.startsWith('/')) {
      command = command.substring(1);
    }

    final String subPath = '/$command';
    final String methodU = method.toUpperCase();

    switch (methodU) {
      case 'GET':
        _module.get(subPath, h);
        break;
      case 'PUT':
        _module.put(subPath, h);
        break;
      case 'PATCH':
        _module.patch(subPath, h);
        break;
      case 'DELETE':
        _module.delete(subPath, h);
        break;
      default:
        _module.post(subPath, h);
    }

    // Register metadata for Swagger
    UseCaseDocMeta doc = UseCaseDocMeta(
      summary: summary ?? 'Use case $command in module $moduleName',
      description: description ?? 'Auto-generated documentation for $command',
      tags: [moduleName],
    );

    apiRegistry.routes.add(
      UseCaseRegistration(
        module: moduleName,
        command: command,
        method: methodU,
        path: '${_normalizeBase(basePath)}/$moduleName/$command',
        factory: usecaseFactory,
        doc: doc,
        inputExample: inputExample,
        outputExample: outputExample,
      ),
    );

    return this;
  }

  void _mount() {
    _root.mount('${_normalizeBase(basePath)}/$moduleName', _module.call);
  }

  String _normalizeBase(String p) {
    if (p.isEmpty) return '';
    return p.startsWith('/') ? p : '/$p';
  }
}

class UseCaseDocMeta {
  /// (Optional) summary/description/tags to enrich Swagger
  final String? summary;
  final String? description;

  /// Tags for grouping in Swagger by module
  /// should be the same as the module name
  final List<String>? tags;

  const UseCaseDocMeta({this.summary, this.description, this.tags});
}

class UseCaseRegistration {
  final String module;
  final String command;
  final String method; // "POST" | "GET" | ...
  final String path; // e.g. "/api/v1/greetings/hello-world"
  final UseCaseFactory factory;
  final UseCaseDocMeta? doc;

  /// Example Input instance for schema extraction and Swagger UI.
  /// The framework extracts schema from this instance — enabling strict `fromJson`.
  final Input inputExample;

  /// Example Output instance for schema extraction and Swagger UI.
  final Output outputExample;

  UseCaseRegistration({
    required this.module,
    required this.command,
    required this.method,
    required this.path,
    required this.factory,
    this.doc,
    required this.inputExample,
    required this.outputExample,
  });
}

class _ApiRegistry {
  final List<UseCaseRegistration> routes = [];
}
