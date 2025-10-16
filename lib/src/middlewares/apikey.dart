import 'package:modular_api/src/utils/env.dart';
import 'package:shelf/shelf.dart';

Middleware apiKey() {
  final apiKey = Env.getString('API_KEY');

  return (Handler handler) {
    return (Request request) async {
      final path = request.requestedUri.path;
      final allowFreeAccess = false
          // Allow free access to the root
          // || path == '/'
          // Allow free access to the Swagger UI and its static resources
          ||
          path.startsWith('/docs');

      if (allowFreeAccess) {
        return handler(request);
      }

      // For the rest, validate API Key
      final key = request.headers['x-api-key'];
      // In x-api-key header avoid using $ at the start of an expression
      // as it may be confused with a variable
      if (key != apiKey) {
        return Response.forbidden('Access denied');
      }

      return handler(request);
    };
  };
}
