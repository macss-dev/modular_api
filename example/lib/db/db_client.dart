import 'package:modular_api/modular_api.dart';

/// Factory para crear un cliente ODBC apuntando a SQL Server.
/// Lee variables de entorno:
/// - MSSQL_DSN
/// - MSSQL_USER
/// - MSSQL_PASSWORD
DbClient createSqlServerClient({bool autoConnect = false}) {
  final dsn = Env.getString('MSSQL_DSN');
  final user = Env.getString('MSSQL_USER');
  final password = Env.getString('MSSQL_PASSWORD');

  return DbClient(
    dsn: dsn,
    username: user,
    password: password,
    autoConnect: autoConnect,
  );
}

/// Factory para crear un cliente ODBC apuntando a Oracle.
/// Lee variables de entorno:
/// - ORACLE_DSN
/// - ORACLE_USER
/// - ORACLE_PASSWORD
DbClient createOracleClient({bool autoConnect = false}) {
  final dsn = Env.getString('ORACLE_DSN');
  final user = Env.getString('ORACLE_USER');
  final password = Env.getString('ORACLE_PASSWORD');

  return DbClient(
    dsn: dsn,
    username: user,
    password: password,
    autoConnect: autoConnect,
  );
}
