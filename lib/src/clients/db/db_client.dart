import 'package:modular_api/src/clients/db/odbc/odbc.dart';

/// Minimal wrapper for ODBC using DSN.
/// - Uses exclusively DSN + username + password.
/// - Executes a script without parameters (query or procedure).
class DbClient {
  final String dsn;
  final String username;
  final String password;

  /// Automatically connects on the first run() if true.
  final bool autoConnect;

  late final Odbc _odbc;
  bool _connected = false;

  DbClient({
    required this.dsn,
    required this.username,
    required this.password,
    this.autoConnect = true,
  }) {
    _odbc = Odbc(dsn: dsn);

    /// Only DSN
  }

  bool get isConnected => _connected;

  /// Opens the ODBC connection using DSN/username/password.
  Future<void> connect() async {
    if (_connected) return;
    await _odbc.connect(username: username, password: password);
    _connected = true;
  }

  /// Closes the connection.
  Future<void> disconnect() async {
    if (!_connected) return;
    await _odbc.disconnect();
    _connected = false;
  }

  /// Runs a *parameterless* script, either a procedure or SQL.
  ///
  /// Reglas:
  /// - If `script` is already `{CALL ...}` → it is sent as-is.
  /// - If `script` has no spaces and does not start with an SQL keyword → it's assumed to be a *procedure*
  ///   and executed as `{CALL name()}`.
  /// - Otherwise → it is sent as raw SQL.
  ///
  /// Devuelve las filas (si las hay) como `List<Map<String,dynamic>>`.
  Future<List<Map<String, dynamic>>> run(String script) async {
    await _maybeConnect();

    final t = script.trim();

    return _odbc.execute(t);
  }

  /// Runs the full flow: connect -> run -> disconnect.
  ///
  /// Recommended usage:
  /// final rows = await db.execute('SELECT ...');
  ///
  /// Uses try/catch/finally to guarantee the connection is closed.
  /// Returns rows as `List<Map<String,dynamic>>` or rethrows the exception.
  Future<List<Map<String, dynamic>>> execute(String script) async {
    try {
      await connect();
      final rows = await run(script);
      return rows;
    } catch (e) {
      // Re-throw after optionally logging. Here we rethrow so the caller handles it.
      // You can integrate a logger to record I/O if desired.
      rethrow;
    } finally {
      // Ensure we attempt to disconnect. Do not propagate disconnect exceptions.
      try {
        await disconnect();
      } catch (_) {
        // Ignorar errores al desconectar.
      }
    }
  }

  // ----------------- Internals -----------------
  Future<void> _maybeConnect() async {
    if (!_connected && autoConnect) {
      await connect();
    } else if (!_connected) {
      throw StateError(
          'Connection not open. Call connect() or use autoConnect=true.');
    }
  }
}
