import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart';

Future<dynamic> httpClient({
  required String method,
  required String baseUrl,
  required String endpoint,
  Map<String, String>? headers,
  Map<String, dynamic>? body,
  String errorMessage = 'Error in HTTP request',
}) async {
  try {
    final url = Uri.parse('$baseUrl/$endpoint');
    late Response response;
    final effectiveHeaders = {
      'Content-Type': 'application/json',
      if (headers != null) ...headers,
    };

    switch (method.toUpperCase()) {
      case 'GET':
        response = await get(
          url,
          headers: effectiveHeaders,
        ).timeout(const Duration(seconds: 30));
        break;
      case 'POST':
        response = await post(
          url,
          headers: effectiveHeaders,
          body: jsonEncode(body ?? {}),
        ).timeout(const Duration(seconds: 30));
        break;
      case 'PATCH':
        response = await patch(
          url,
          headers: effectiveHeaders,
          body: body != null ? jsonEncode(body) : null,
        ).timeout(const Duration(seconds: 30));
        break;
      default:
        throw Exception('Unsupported HTTP method: $method');
    }

    if (response.statusCode == 200) {
      return jsonDecode(response.body);
    } else {
      throw Exception('$errorMessage: ${response.statusCode}');
    }
  } catch (e) {
    stderr.writeln('HTTP Client Error: $e');
    throw Exception('$errorMessage: [Connection error] - $e');
  }
}
