import 'package:shelf/shelf.dart';

/// Prefer building your own CORS middleware according to your needs.
/// use this as a starting point.
Middleware exampleCorsMiddleware() {
  // final port = Env.getInt('PORT');
  // final environment = Env.getString('ENV'); // 'dev' o 'prod'

  // final allowedOrigins = [
  //   'http://localhost:$port',
  //   'http://192.168.10.18:$port',
  // ];

  return (Handler handler) {
    return (Request request) async {
      // stdout.writeln('CORS middleware processing request: ${request.method} ${request.requestedUri}');
      // if (environment != 'dev') {
      //   // Si no es dev, no se permiten CORS
      //   return Response.forbidden('CORS not allowed in this environment');
      // }

      // final origin = request.headers['origin'];
      // final isAllowed = origin != null && allowedOrigins.contains(origin);

      // CORS headers to add if allowed
      final corsHeaders = {
        // if (isAllowed) 'Access-Control-Allow-Origin': origin,
        // if (isAllowed) 'Access-Control-Allow-Credentials': 'true',
        'Access-Control-Allow-Origin': '*', // Allow all origins
        'Access-Control-Allow-Credentials': 'true',
        'Access-Control-Allow-Methods': 'GET, POST, PUT, DELETE, OPTIONS',
        'Access-Control-Allow-Headers':
            'Origin, Content-Type, Accept, Authorization, x-api-key',
      };

      /// Handling preflight requests (OPTIONS)
      if (request.method == 'OPTIONS') {
        return Response.ok('', headers: corsHeaders);
      }

      // Continue with normal request
      final response = await handler(request);
      return response.change(headers: {...response.headers, ...corsHeaders});
    };
  };
}
