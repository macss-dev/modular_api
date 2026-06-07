import 'dart:convert';
import 'package:shelf/shelf.dart';
import 'package:shelf_router/shelf_router.dart';

import '../logger/logger.dart';
import '../logger/logging_middleware.dart';
import '../schema/field.dart';
import 'usecase.dart';
import 'use_case_exception.dart';

/// Generic handler for any UseCase
Handler useCaseHttpHandler(
  UseCase Function(Map<String, dynamic>) fromJson, {
  Input? inputExample,
}) {
  const jsonHeaders = {'content-type': 'application/json; charset=utf-8'};

  // Capture schema at creation time — enables pre-validation
  // before fromJson, so strict factories never crash.
  final preValidationFields = inputExample?.schemaFields;

  return (Request req) async {
    try {
      // 1. Extract JSON (either from body or params)
      final data = req.method.toUpperCase() == 'GET'
          ? await _jsonFromUrl(req)
          : await _jsonFromBody(req);

      // 2. Pre-validate BEFORE fromJson (when example provides schema)
      if (preValidationFields != null) {
        validateJsonFields(data, preValidationFields);
      }

      // 3. Build and validate the UseCase
      final useCase = fromJson(data);

      // 3a. Post-validate for legacy path (no inputExample)
      if (preValidationFields == null) {
        final inputFields = useCase.input.schemaFields;
        if (inputFields != null) {
          validateJsonFields(data, inputFields);
        }
      }

      final validationError = useCase.validate();
      if (validationError != null) {
        return Response(
          400,
          headers: jsonHeaders,
          body: jsonEncode({'error': validationError}),
        );
      }

      // 3. Inject logger from middleware context
      useCase.logger = req.context[loggerContextKey] as ModularLogger?;

      // 4. Execute the use case
      final output = await useCase.execute();

      // 5. Serialize the response and return with the appropriate status code
      return Response(
        output.statusCode,
        headers: jsonHeaders,
        body: jsonEncode(output.toJson()),
      );
    } on UseCaseException catch (e) {
      final logger = req.context[loggerContextKey] as ModularLogger?;
      logger?.error('UseCaseException',
          fields: {'error': e.toString(), 'status': e.statusCode});
      return Response(
        e.statusCode,
        headers: jsonHeaders,
        body: jsonEncode(e.toJson()),
      );
    } on InputValidationException catch (e) {
      return Response(
        400,
        headers: jsonHeaders,
        body: jsonEncode({'error': e.message}),
      );
    } catch (e) {
      final logger = req.context[loggerContextKey] as ModularLogger?;
      logger?.error('Unexpected error in use case handler',
          fields: {'error': e.toString()});
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
