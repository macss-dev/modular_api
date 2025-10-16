import 'dart:io';

import 'package:dotenv/dotenv.dart';

class EnvKeyNotFoundException implements Exception {
  final String key;
  EnvKeyNotFoundException(this.key);

  @override
  String toString() => 'EnvKeyNotFoundException: key not found: $key';
}

class EnvParseException implements Exception {
  final String key;
  final String value;
  EnvParseException(this.key, this.value);

  @override
  String toString() =>
      'EnvParseException: could not parse key: $key value: $value';
}

class Env {
  static final DotEnv _env = DotEnv()..load();

  /// get String value from .env file
  /// Throws [EnvKeyNotFoundException] if the key does not exist.
  static String getString(String key) {
    final raw = _env[key];
    if (raw == null) {
      throw EnvKeyNotFoundException(key);
    }
    var value = raw;
    // Only remove quotes if they are at the start and end
    if (value.length >= 2 && value.startsWith('"') && value.endsWith('"')) {
      value = value.substring(1, value.length - 1);
    }
    return value;
  }

  /// get int value from .env file
  /// Throws [EnvKeyNotFoundException] if the key does not exist.
  /// Throws [EnvParseException] if the value cannot be parsed to int.
  static int getInt(String key) {
    final raw = _env[key];
    if (raw == null) {
      throw EnvKeyNotFoundException(key);
    }
    final parsed = int.tryParse(raw);
    if (parsed == null) {
      throw EnvParseException(key, raw);
    }
    return parsed;
  }

  /// set String value in .env file
  static Future<void> setString(String key, String value) async {
    final envFile = '${Directory.current.path}/.env';
    final file = File(envFile);
    List<String> lines = [];
    if (await file.exists()) {
      lines = await file.readAsLines();
    }
    bool found = false;
    for (int i = 0; i < lines.length; i++) {
      if (lines[i].startsWith('$key=')) {
        lines[i] = '$key=$value';
        found = true;
      }
    }
    if (!found) lines.add('$key=$value');
    await file.writeAsString(lines.join('\n'));
  }
}
