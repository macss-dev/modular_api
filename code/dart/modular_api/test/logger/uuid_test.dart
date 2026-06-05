import 'package:test/test.dart';
import 'package:modular_api/src/core/logger/uuid.dart';

void main() {
  group('generateUuidV4', () {
    test('has correct length of 36 characters', () {
      final uuid = generateUuidV4();
      expect(uuid.length, 36);
    });

    test('matches UUID v4 format: xxxxxxxx-xxxx-4xxx-[89ab]xxx-xxxxxxxxxxxx',
        () {
      final uuid = generateUuidV4();
      final pattern = RegExp(
        r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$',
      );
      expect(uuid, matches(pattern),
          reason: 'UUID "$uuid" does not match v4 format');
    });

    test('version digit (position 14) is always 4', () {
      for (var i = 0; i < 100; i++) {
        final uuid = generateUuidV4();
        expect(uuid[14], '4', reason: 'UUID "$uuid" version digit is not 4');
      }
    });

    test('variant digit (position 19) is always 8, 9, a, or b', () {
      for (var i = 0; i < 100; i++) {
        final uuid = generateUuidV4();
        expect(
          ['8', '9', 'a', 'b'].contains(uuid[19]),
          isTrue,
          reason:
              'UUID "$uuid" variant digit "${uuid[19]}" is not in [8,9,a,b]',
        );
      }
    });

    test('two consecutive calls produce different values', () {
      final a = generateUuidV4();
      final b = generateUuidV4();
      expect(a, isNot(equals(b)));
    });

    test('dashes are at positions 8, 13, 18, 23', () {
      final uuid = generateUuidV4();
      expect(uuid[8], '-');
      expect(uuid[13], '-');
      expect(uuid[18], '-');
      expect(uuid[23], '-');
    });
  });
}
