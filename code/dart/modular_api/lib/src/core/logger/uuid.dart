import 'dart:math';

final _random = Random.secure();

/// Generates a RFC 4122 version 4 UUID using `Random.secure()`.
///
/// Format: `xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx`
/// where `y` ∈ {8, 9, a, b} (variant 1).
///
/// Zero external dependencies — uses only `dart:math`.
String generateUuidV4() {
  // 16 random bytes
  final bytes = List<int>.generate(16, (_) => _random.nextInt(256));

  // Set version (4) → byte 6 high nibble = 0100
  bytes[6] = (bytes[6] & 0x0F) | 0x40;

  // Set variant (10xx) → byte 8 high bits = 10
  bytes[8] = (bytes[8] & 0x3F) | 0x80;

  // Format as hex string with dashes
  String hex(int byte) => byte.toRadixString(16).padLeft(2, '0');

  return '${hex(bytes[0])}${hex(bytes[1])}${hex(bytes[2])}${hex(bytes[3])}-'
      '${hex(bytes[4])}${hex(bytes[5])}-'
      '${hex(bytes[6])}${hex(bytes[7])}-'
      '${hex(bytes[8])}${hex(bytes[9])}-'
      '${hex(bytes[10])}${hex(bytes[11])}${hex(bytes[12])}${hex(bytes[13])}${hex(bytes[14])}${hex(bytes[15])}';
}
