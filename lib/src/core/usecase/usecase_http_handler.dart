import 'dart:convert';
import 'package:shelf/shelf.dart';
import 'package:shelf_router/shelf_router.dart';

import 'usecase.dart';

/// Generic handler for any UseCase
Handler useCaseHttpHandler(UseCase Function(Map<String, dynamic>) fromJson) {
  const jsonHeaders = {'content-type': 'application/json; charset=utf-8'};

  return (Request req) async {
    try {
      // 1. Extract JSON (either from body or params)
      final data = req.method.toUpperCase() == 'GET'
          ? await _jsonFromUrl(req)
          : await _jsonFromBody(req);

      // 2. Build and validate the UseCase
      final useCase = fromJson(data);
      final validationError = useCase.validate();
      if (validationError != null) {
        return Response(
          400,
          headers: jsonHeaders,
          body: jsonEncode({'error': validationError}),
        );
      }

      // 3. Execute the use case
      await useCase.execute();

      // 4. Serialize the response and return
      return Response.ok(jsonEncode(useCase.toJson()), headers: jsonHeaders);
    } catch (e) {
      // Here you can log the error
      return Response(
        500,
        headers: jsonHeaders,
        body: jsonEncode({'error': 'Internal server error'}),
      );
    }
  };
}

/// Extracts JSON directly from the body (POST/PATCH)
Future<Map<String, dynamic>> _jsonFromBody(Request req) async {
  final payload = await req.readAsString();
  return jsonDecode(payload) as Map<String, dynamic>;
}

/// Extracts JSON from path-params and query-params (GET)
Future<Map<String, dynamic>> _jsonFromUrl(Request req) async {
  final qp = req.url.queryParameters;
  final pp = req.params;
  return {...qp, ...pp};
}
