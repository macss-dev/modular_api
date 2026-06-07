import 'dart:convert';
import 'package:shelf/shelf.dart';
import 'health_service.dart';

/// Creates a Shelf [Handler] that responds to `GET /health`
/// with `application/health+json` following the IETF draft.
///
/// Returns 200 for pass/warn, 503 for fail.
Handler healthHandler(HealthService service) {
  return (Request request) async {
    final response = await service.evaluate();

    return Response(
      response.httpStatusCode,
      headers: {'content-type': 'application/health+json'},
      body: jsonEncode(response.toJson()),
    );
  };
}
