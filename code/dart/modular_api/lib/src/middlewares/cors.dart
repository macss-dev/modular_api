/// Configurable CORS middleware — no external dependencies.
///
/// Sets `Access-Control-Allow-Origin`, `Access-Control-Allow-Methods`,
/// and `Access-Control-Allow-Headers` on every response. Preflight
/// `OPTIONS` requests are short-circuited with 204 No Content.
///
/// Mirror of `cors()` in TypeScript and `cors_middleware()` in Python.
///
/// Usage:
/// ```dart
/// api.use(corsMiddleware());
/// api.use(corsMiddleware(origin: 'https://myapp.com'));
/// api.use(corsMiddleware(origin: ['https://a.com', 'https://b.com']));
/// ```
library;

import 'package:shelf/shelf.dart';

const _defaultMethods = 'GET,POST,PUT,PATCH,DELETE,OPTIONS';
const _defaultHeaders = 'Content-Type,Authorization';

/// Returns a Shelf [Middleware] that injects CORS headers on every response.
///
/// [origin] — Allowed origins. Accepts a [String] or `List<String>`.
/// Defaults to `'*'` (all origins).
///
/// [methods] — Allowed HTTP methods. Defaults to
/// `'GET,POST,PUT,PATCH,DELETE,OPTIONS'`.
///
/// [allowedHeaders] — Allowed request headers. Defaults to
/// `'Content-Type,Authorization'`.
Middleware corsMiddleware({
  Object? origin,
  String? methods,
  String? allowedHeaders,
}) {
  final resolvedOrigin = switch (origin) {
    List<String> list => list.join(', '),
    String value => value,
    _ => '*',
  };

  final resolvedMethods = methods ?? _defaultMethods;
  final resolvedHeaders = allowedHeaders ?? _defaultHeaders;

  return (Handler handler) {
    return (Request request) async {
      final corsHeaders = {
        'Access-Control-Allow-Origin': resolvedOrigin,
        'Access-Control-Allow-Methods': resolvedMethods,
        'Access-Control-Allow-Headers': resolvedHeaders,
      };

      // Short-circuit OPTIONS preflight
      if (request.method == 'OPTIONS') {
        return Response(204, headers: corsHeaders);
      }

      final response = await handler(request);
      return response.change(headers: {...response.headers, ...corsHeaders});
    };
  };
}
