import 'dart:async';
import 'dart:convert';

import 'package:modular_api/src/core/logger/logger.dart';
import 'package:modular_api/src/core/logger/logging_middleware.dart';
import 'package:modular_api/src/core/modular_api.dart';
import 'package:modular_api/src/core/request_pipeline_audit.dart';
import 'package:shelf/shelf.dart';
import 'package:shelf_router/shelf_router.dart';

const hostApiVersion = '0.1.0';
const _allowedMiddlewareSlots = {'preRouting', 'preHandler', 'postHandler'};

class PluginRequirement {
  final String type;
  final String id;
  final String? version;

  const PluginRequirement({
    required this.type,
    required this.id,
    this.version,
  });
}

class PluginManifest {
  final String id;
  final String displayName;
  final String version;
  final String hostApiVersion;
  final List<PluginRequirement> requires;
  final List<PluginRequirement> optional;
  final Map<String, dynamic>? contributes;

  const PluginManifest({
    required this.id,
    required this.displayName,
    required this.version,
    required this.hostApiVersion,
    this.requires = const [],
    this.optional = const [],
    this.contributes,
  });
}

class HostMetadata {
  final String basePath;
  final String title;
  final String version;
  final String hostApiVersion;

  const HostMetadata({
    required this.basePath,
    required this.title,
    required this.version,
    required this.hostApiVersion,
  });
}

class PluginValidationResult {
  final String code;
  final String message;
  final String? pluginId;
  final String? resourceId;
  final bool blocking;

  const PluginValidationResult({
    required this.code,
    required this.message,
    this.pluginId,
    this.resourceId,
    this.blocking = true,
  });
}

class Capability<T> {
  final String id;
  final String version;
  final T value;

  const Capability({
    required this.id,
    required this.version,
    required this.value,
  });
}

typedef CapabilityHandle<T> = Capability<T>;

class ModuleExtensionPoint {
  final String id;
  final String mode;
  final String? description;

  const ModuleExtensionPoint({
    required this.id,
    required this.mode,
    this.description,
  });
}

class ModuleExtensionContribution {
  final String extensionPointId;
  final String moduleName;
  final Object? value;

  const ModuleExtensionContribution({
    required this.extensionPointId,
    required this.moduleName,
    required this.value,
  });
}

class RegisteredModuleView {
  final String name;

  const RegisteredModuleView({required this.name});
}

class RegisteredUseCaseView {
  final String module;
  final String command;
  final String method;
  final String path;

  const RegisteredUseCaseView({
    required this.module,
    required this.command,
    required this.method,
    required this.path,
  });
}

class PluginRequestContext {
  final String requestId;
  final ModularLogger? logger;
  final String method;
  final String path;
  final Map<String, String> headers;
  final Map<String, String> query;
  final Object? body;
  final Map<String, String> pathParams;
  final Map<String, CapabilityHandle> Function() capabilities;

  const PluginRequestContext({
    required this.requestId,
    required this.logger,
    required this.method,
    required this.path,
    required this.headers,
    required this.query,
    required this.body,
    required this.pathParams,
    required this.capabilities,
  });
}

typedef PluginRouteHandler = FutureOr<Response> Function(
  PluginRequestContext context,
);

class PluginRoute {
  final String id;
  final String method;
  final String path;
  final String visibility;

  /// Optional standard OpenAPI Operation object (summary, parameters,
  /// requestBody, responses — including binary content types). When present
  /// on a `custom` or `transport` route, the official OpenApiPlugin merges
  /// it into the generated spec so the route appears in /openapi.json and
  /// /docs (ADR-0003).
  final Map<String, dynamic>? openapi;
  final PluginRouteHandler handler;

  const PluginRoute({
    required this.id,
    required this.method,
    required this.path,
    required this.visibility,
    this.openapi,
    required this.handler,
  });
}

/// Read view of a plugin route already registered on the host (ADR-0003).
class RegisteredPluginRouteView {
  final String? pluginId;
  final String id;
  final String method;

  /// Absolute mounted path (basePath already joined).
  final String path;
  final String visibility;
  final Map<String, dynamic>? openapi;

  const RegisteredPluginRouteView({
    this.pluginId,
    required this.id,
    required this.method,
    required this.path,
    required this.visibility,
    this.openapi,
  });
}

typedef PluginMiddlewareHandler = Middleware;

class PluginMiddleware {
  final String id;
  final String slot;
  final int order;
  final PluginMiddlewareHandler handler;

  const PluginMiddleware({
    required this.id,
    required this.slot,
    this.order = 0,
    required this.handler,
  });
}

abstract class PluginHost {
  HostMetadata metadata();
  List<RegisteredModuleView> modules();
  List<RegisteredUseCaseView> useCases();
  List<RegisteredPluginRouteView> routes();
  void registerRoute(PluginRoute route);
  void registerMiddleware(PluginMiddleware middleware);
  void exposeCapability(Capability capability);
  CapabilityHandle? resolveCapability(String id);
  CapabilityHandle requireCapability(String id);
  void declareModuleExtensionPoint(ModuleExtensionPoint point);
  void contributeModuleExtension(ModuleExtensionContribution contribution);
  void addStartupValidation(PluginValidationResult validation);
  void onShutdown(FutureOr<void> Function() callback);
}

abstract class Plugin {
  PluginManifest get manifest;
  void setup(PluginHost host);
}

abstract class ValidatingPlugin {
  List<PluginValidationResult> validate(PluginHost host);
}

abstract class ShutdownAwarePlugin {
  FutureOr<void> shutdown();
}

class PluginHostError implements Exception {
  final String code;
  final String message;
  final String? pluginId;
  final String? resourceId;

  const PluginHostError(
    this.code,
    this.message, {
    this.pluginId,
    this.resourceId,
  });

  @override
  String toString() => 'PluginHostError($code): $message';
}

class RuntimePluginHost implements PluginHost {
  final HostMetadata _metadata;
  final List<_RuntimePluginRoute> _routes = [];
  final List<_RuntimePluginMiddleware> _middlewares = [];
  final Map<String, CapabilityHandle> _capabilities = {};
  final Map<String, ModuleExtensionPoint> _extensionPoints = {};
  final Map<String, List<Object?>> _extensionValues = {};
  final List<PluginValidationResult> _startupValidations = [];
  final List<FutureOr<void> Function()> _shutdownCallbacks = [];
  final Set<String> _routeKeys = <String>{};
  int _middlewareSequence = 0;
  String? _activePluginId;
  bool _frozen = false;

  RuntimePluginHost({
    required String basePath,
    required String title,
    required String version,
  }) : _metadata = HostMetadata(
          basePath: _normalizeBasePath(basePath),
          title: title,
          version: version,
          hostApiVersion: hostApiVersion,
        );

  @override
  HostMetadata metadata() => _metadata;

  @override
  List<RegisteredModuleView> modules() {
    final names = apiRegistry.routes.map((route) => route.module).toSet();
    return names.map((name) => RegisteredModuleView(name: name)).toList();
  }

  @override
  List<RegisteredUseCaseView> useCases() {
    return apiRegistry.routes
        .map(
          (route) => RegisteredUseCaseView(
            module: route.module,
            command: route.command,
            method: route.method,
            path: route.path,
          ),
        )
        .toList();
  }

  @override
  void registerRoute(PluginRoute route) {
    _assertMutable();
    final finalPath = _joinPath(_metadata.basePath, route.path);
    final routeKey = '${route.method.toUpperCase()} $finalPath';
    if (_routeKeys.contains(routeKey)) {
      throw PluginHostError(
        'ROUTE_CONFLICT',
        'Route conflict for $routeKey',
        resourceId: routeKey,
      );
    }

    _routeKeys.add(routeKey);
    _routes.add(
      _RuntimePluginRoute(
        finalPath: finalPath,
        route: route,
        pluginId: _activePluginId,
      ),
    );
  }

  @override
  List<RegisteredPluginRouteView> routes() {
    return _routes
        .map(
          (registration) => RegisteredPluginRouteView(
            pluginId: registration.pluginId,
            id: registration.route.id,
            method: registration.route.method,
            path: registration.finalPath,
            visibility: registration.route.visibility,
            openapi: registration.route.openapi,
          ),
        )
        .toList();
  }

  @override
  void registerMiddleware(PluginMiddleware middleware) {
    _assertMutable();
    if (!_allowedMiddlewareSlots.contains(middleware.slot)) {
      throw PluginHostError(
        'PLUGIN_VALIDATION_FAILED',
        'Unknown middleware slot: ${middleware.slot}',
        resourceId: middleware.id,
      );
    }

    _middlewares.add(
      _RuntimePluginMiddleware(
        middleware: PluginMiddleware(
          id: middleware.id,
          slot: middleware.slot,
          order: middleware.order,
          handler: _instrumentPluginMiddleware(middleware, _activePluginId),
        ),
        sequence: _middlewareSequence++,
      ),
    );
  }

  void beginPluginSetup(String pluginId) {
    _assertMutable();
    _activePluginId = pluginId;
  }

  void endPluginSetup() {
    _activePluginId = null;
  }

  @override
  void exposeCapability(Capability capability) {
    _assertMutable();
    if (_capabilities.containsKey(capability.id)) {
      throw PluginHostError(
        'CAPABILITY_CONFLICT',
        'Capability already exposed: ${capability.id}',
        resourceId: capability.id,
      );
    }
    _capabilities[capability.id] = capability;
  }

  @override
  CapabilityHandle? resolveCapability(String id) => _capabilities[id];

  @override
  CapabilityHandle requireCapability(String id) {
    final capability = resolveCapability(id);
    if (capability == null) {
      throw PluginHostError(
        'CAPABILITY_REQUIRED_MISSING',
        'Missing capability: $id',
        resourceId: id,
      );
    }
    return capability;
  }

  @override
  void declareModuleExtensionPoint(ModuleExtensionPoint point) {
    _assertMutable();
    if (_extensionPoints.containsKey(point.id)) {
      throw PluginHostError(
        'MODULE_EXTENSION_POINT_CONFLICT',
        'Duplicate extension point: ${point.id}',
        resourceId: point.id,
      );
    }
    _extensionPoints[point.id] = point;
  }

  @override
  void contributeModuleExtension(ModuleExtensionContribution contribution) {
    _assertMutable();
    final point = _extensionPoints[contribution.extensionPointId];
    if (point == null) {
      throw PluginHostError(
        'MODULE_EXTENSION_CONFLICT',
        'Unknown extension point: ${contribution.extensionPointId}',
        resourceId: contribution.extensionPointId,
      );
    }

    final key = '${contribution.extensionPointId}:${contribution.moduleName}';
    final values = _extensionValues.putIfAbsent(key, () => <Object?>[]);
    if (point.mode == 'single' && values.isNotEmpty) {
      throw PluginHostError(
        'MODULE_EXTENSION_CONFLICT',
        'Duplicate contribution for single extension point $key',
        resourceId: key,
      );
    }
    values.add(contribution.value);
  }

  @override
  void addStartupValidation(PluginValidationResult validation) {
    _assertMutable();
    _startupValidations.add(validation);
  }

  @override
  void onShutdown(FutureOr<void> Function() callback) {
    _assertMutable();
    _shutdownCallbacks.add(callback);
  }

  void freeze() {
    _frozen = true;
  }

  void assertValid([Iterable<PluginValidationResult> additionalValidations = const []]) {
    for (final validation in [..._startupValidations, ...additionalValidations]) {
      if (validation.blocking) {
        throw PluginHostError(
          validation.code,
          validation.message,
          pluginId: validation.pluginId,
          resourceId: validation.resourceId,
        );
      }
    }
  }

  void applyRoutes(Router root) {
    for (final registration in _routes) {
      final handler = _buildHandler(registration.route);
      switch (registration.route.method.toUpperCase()) {
        case 'GET':
          root.get(registration.finalPath, handler);
          break;
        case 'PUT':
          root.put(registration.finalPath, handler);
          break;
        case 'PATCH':
          root.patch(registration.finalPath, handler);
          break;
        case 'DELETE':
          root.delete(registration.finalPath, handler);
          break;
        default:
          root.post(registration.finalPath, handler);
      }
    }
  }

  List<PluginMiddleware> middlewaresForSlot(String slot) {
    final filtered = _middlewares
        .where((middleware) => middleware.middleware.slot == slot)
        .toList();
    filtered.sort((left, right) {
      final orderDelta = left.middleware.order.compareTo(right.middleware.order);
      if (orderDelta != 0) {
        return orderDelta;
      }
      return left.sequence.compareTo(right.sequence);
    });
    return filtered.map((middleware) => middleware.middleware).toList();
  }

  Future<void> shutdown() async {
    for (final callback in _shutdownCallbacks.reversed) {
      await callback();
    }
  }

  Handler _buildHandler(PluginRoute route) {
    return (Request request) async {
      final logger = request.context[loggerContextKey] as ModularLogger?;
      final body = await _readBody(request);
      final response = await route.handler(
        PluginRequestContext(
          requestId: _resolveRequestId(request, logger),
          logger: logger,
          method: request.method,
          path: request.requestedUri.path,
          headers: Map<String, String>.from(request.headers),
          query: request.url.queryParameters,
          body: body,
          pathParams: request.params,
          capabilities: () => Map.unmodifiable(_capabilities),
        ),
      );

      return response;
    };
  }

  void _assertMutable() {
    if (_frozen) {
      throw const PluginHostError(
        'PLUGIN_VALIDATION_FAILED',
        'Plugin host registration is frozen',
      );
    }
  }

  static String _normalizeBasePath(String basePath) {
    if (basePath.isEmpty || basePath == '/') {
      return '/';
    }
    return '/${basePath.replaceAll(RegExp(r'^/+|/+$'), '')}';
  }

  static String _normalizeRelativePath(String path) {
    final trimmed = path.trim();
    if (trimmed.isEmpty) {
      throw const PluginHostError(
        'PLUGIN_VALIDATION_FAILED',
        'Plugin route path cannot be empty',
      );
    }
    return '/${trimmed.replaceAll(RegExp(r'^/+|/+$'), '')}';
  }

  static String _joinPath(String basePath, String relativePath) {
    final normalizedBasePath = _normalizeBasePath(basePath);
    final normalizedRelativePath = _normalizeRelativePath(relativePath);
    if (normalizedBasePath == '/') {
      return normalizedRelativePath;
    }
    return '$normalizedBasePath$normalizedRelativePath'
        .replaceAll(RegExp(r'/+'), '/');
  }

  static Future<Object?> _readBody(Request request) async {
    final method = request.method.toUpperCase();
    if (method == 'GET' || method == 'DELETE') {
      return null;
    }

    final raw = await request.readAsString();
    if (raw.isEmpty) {
      return null;
    }

    try {
      return jsonDecode(raw);
    } catch (_) {
      return raw;
    }
  }

  static String _resolveRequestId(Request request, ModularLogger? logger) {
    final header = request.headers['X-Request-ID'];
    if (header != null && header.isNotEmpty) {
      return header;
    }
    if (logger is RequestScopedLogger) {
      return logger.traceId;
    }
    return 'unknown';
  }
}

List<Plugin> orderPlugins(Iterable<Plugin> plugins) {
  final pluginList = plugins.toList(growable: false);
  final pluginsById = <String, Plugin>{
    for (final plugin in pluginList) plugin.manifest.id: plugin,
  };
  final visitState = <String, _PluginVisitState>{};
  final ordered = <Plugin>[];

  void visit(Plugin plugin) {
    final pluginId = plugin.manifest.id;
    final state = visitState[pluginId];
    if (state == _PluginVisitState.visited) {
      return;
    }

    if (state == _PluginVisitState.visiting) {
      throw PluginHostError(
        'PLUGIN_DEPENDENCY_CYCLE',
        'Plugin dependency cycle detected at $pluginId',
        pluginId: pluginId,
        resourceId: pluginId,
      );
    }

    visitState[pluginId] = _PluginVisitState.visiting;
    for (final requirement in plugin.manifest.requires) {
      if (requirement.type != 'plugin') {
        continue;
      }

      final dependency = pluginsById[requirement.id];
      if (dependency == null) {
        throw PluginHostError(
          'PLUGIN_DEPENDENCY_MISSING',
          'Missing required plugin dependency ${requirement.id} for $pluginId',
          pluginId: pluginId,
          resourceId: requirement.id,
        );
      }

      visit(dependency);
    }

    visitState[pluginId] = _PluginVisitState.visited;
    ordered.add(plugin);
  }

  for (final plugin in pluginList) {
    visit(plugin);
  }

  return ordered;
}

enum _PluginVisitState { visiting, visited }

class _RuntimePluginRoute {
  final String finalPath;
  final PluginRoute route;
  final String? pluginId;

  const _RuntimePluginRoute({
    required this.finalPath,
    required this.route,
    this.pluginId,
  });
}

class _RuntimePluginMiddleware {
  final PluginMiddleware middleware;
  final int sequence;

  const _RuntimePluginMiddleware({required this.middleware, required this.sequence});
}

Middleware _instrumentPluginMiddleware(
  PluginMiddleware middleware,
  String? pluginId,
) {
  return (Handler innerHandler) {
    FutureOr<Response> observedInnerHandler(Request request) {
      clearShortCircuitCandidate(request, middleware.id);
      return innerHandler(request);
    }
    final wrappedHandler = middleware.handler(observedInnerHandler);

    return (Request request) async {
      setShortCircuitCandidate(
        request,
        ShortCircuitAuditEntry(
          pluginId: pluginId ?? 'unknown',
          middlewareId: middleware.id,
          slot: middleware.slot,
        ),
      );

      try {
        return await wrappedHandler(request);
      } catch (_) {
        clearShortCircuitCandidate(request, middleware.id);
        rethrow;
      }
    };
  };
}