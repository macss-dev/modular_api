import 'dart:io';
import 'package:modular_api/modular_api.dart';
import 'package:modular_api/src/core/usecase/usecase_http_handler.dart';
import 'package:shelf/shelf.dart';
import 'package:shelf/shelf_io.dart' as shelf_io;
import 'package:shelf_router/shelf_router.dart';

final apiRegistry = _ApiRegistry();

typedef UseCaseFactory = UseCase Function(Map<String, dynamic> json);

class ModularApi {
  final Router _root = Router();
  final List<Middleware> _middlewares = [];
  final String basePath;

  ModularApi({this.basePath = '/api'});

  ModularApi module(String name, void Function(ModuleBuilder) build) {
    final m = ModuleBuilder(basePath: basePath, moduleName: name, root: _root);

    build(m);
    m._mount();

    return this;
  }

  ModularApi use(Middleware middleware) {
    _middlewares.add(middleware);
    return this;
  }

  Future<HttpServer> serve({
    InternetAddress? ip,
    required int port,
    Future<void> Function(Router root)? onBeforeServe,
  }) async {
    _root.get('/health', (Request request) => Response.ok('ok'));

    await OpenApi.init(
      title: 'Example API',
      port: port,
      // Customize as needed
      // servers: [
      //   {
      //     'url': 'http://192.168.10.18:$port',
      //     'description': 'PROD'
      //   }
      // ],
    );
    _root.get('/docs', OpenApi.docs);
    // root.get('/openapi.json', OpenApiSpecification.openapiJson);

    if (onBeforeServe != null) {
      await onBeforeServe(_root);
    }
    var pipeline = const Pipeline();
    for (final m in _middlewares) {
      pipeline = pipeline.addMiddleware(m);
    }

    pipeline = pipeline.addMiddleware(logRequests());

    final handler = pipeline.addHandler(_root.call);
    final server = await shelf_io.serve(
      handler,
      ip ?? InternetAddress.anyIPv4,
      port,
    );
    return server;
  }
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

  /// POST by default
  ModuleBuilder usecase(
    String usecaseName,
    UseCaseFactory usecaseFactory, {
    String method = 'POST',
    String? summary,
    String? description,
  }) {
    final Handler h = useCaseHttpHandler(usecaseFactory);
    final String subPath = '/$usecaseName';
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
      summary: summary ?? 'Use case $usecaseName in module $moduleName',
      description:
          description ?? 'Auto-generated documentation for $usecaseName',
      tags: [moduleName],
    );

    apiRegistry.routes.add(
      UseCaseRegistration(
        module: moduleName,
        name: usecaseName,
        method: methodU,
        path: '${_normalizeBase(basePath)}/$moduleName/$usecaseName',
        factory: usecaseFactory,
        doc: doc,
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
  final String name;
  final String method; // "POST" | "GET" | ...
  final String path; // p.ej. "/api/ligo/example"
  final UseCaseFactory factory;
  final UseCaseDocMeta? doc;

  UseCaseRegistration({
    required this.module,
    required this.name,
    required this.method,
    required this.path,
    required this.factory,
    this.doc,
  });
}

class _ApiRegistry {
  final List<UseCaseRegistration> routes = [];
}
