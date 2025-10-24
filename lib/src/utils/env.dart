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
  static final DotEnv _env = DotEnv();
  static bool _envLoaded = false;

  /// Initializes the environment; attempts to load `.env` if present.
  static void init() {
    final envFile = File('${Directory.current.path}/.env');
    if (envFile.existsSync()) {
      _env.load();
      _envLoaded = true;
    } else {
      stdout.writeln('[Env] .env file not found, falling back to Platform.environment');
    }
  }

  static String _getRaw(String key) {
    // Intentar leer desde .env si fue cargado
    if (_envLoaded) {
      final raw = _env[key];
      if (raw != null) return raw;
    }

    // Intentar leer desde variables del sistema
    final envValue = Platform.environment[key];
    if (envValue != null) return envValue;

    // Si no se encontró en ninguna fuente, lanzar excepción
    throw EnvKeyNotFoundException(key);
  }

  static String getString(String key) {
    final raw = _getRaw(key);
    var value = raw;
    if (value.length >= 2 && value.startsWith('"') && value.endsWith('"')) {
      value = value.substring(1, value.length - 1);
    }
    return value;
  }

  static int getInt(String key) {
    final raw = _getRaw(key);
    final parsed = int.tryParse(raw);
    if (parsed == null) {
      throw EnvParseException(key, raw);
    }
    return parsed;
  }
  
  @Deprecated('Avoid using this method as it may lead to unexpected behavior.')
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