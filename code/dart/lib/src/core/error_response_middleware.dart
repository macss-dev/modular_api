import 'dart:convert';

import 'package:shelf/shelf.dart';

import 'logger/logger.dart';
import 'logger/logging_middleware.dart';

Middleware errorResponseMiddleware() {
  const jsonHeaders = {'content-type': 'application/json; charset=utf-8'};

  return (Handler innerHandler) {
    return (Request request) async {
      try {
        return await innerHandler(request);
      } catch (error) {
        final logger = request.context[loggerContextKey] as ModularLogger?;
        logger?.error(
          'Unhandled error in request pipeline',
          fields: {'error': error.toString(), 'status': 500},
        );
        return Response(
          500,
          headers: jsonHeaders,
          body: jsonEncode({'error': 'Internal server error'}),
        );
      }
    };
  };
}