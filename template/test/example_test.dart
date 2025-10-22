// ignore: depend_on_referenced_packages
import 'package:test/test.dart';
import 'package:http/http.dart' as http;
import 'dart:convert';

void main() {
  group('API /ligo/example', () {
    test('POST /api/ligo/example status 200', () async {
      final url = Uri.parse('http://localhost:8080/api/ligo/example');
      final body = jsonEncode({
        'id': 2, // must be > 0 and even for success
        'mensaje': 'Test notification',
      });
      final response = await http.post(
        url,
        headers: {'Content-Type': 'application/json'},
        body: body,
      );
      expect(response.statusCode, 200);
    });
  });
}
