import 'dart:io';

final class SqlServerConnectionSettings {
  const SqlServerConnectionSettings({
    required this.host,
    required this.port,
    required this.database,
    required this.username,
    required this.password,
    required this.driver,
  });

  factory SqlServerConnectionSettings.fromEnvironment({
    Map<String, String>? environment,
  }) {
    final env = environment ?? Platform.environment;
    final parsedPort = int.tryParse(env['MODULAR_API_SQLSERVER_PORT'] ?? '');

    return SqlServerConnectionSettings(
      host: env['MODULAR_API_SQLSERVER_HOST'] ?? '127.0.0.1',
      port: parsedPort ?? 14333,
      database: env['MODULAR_API_SQLSERVER_DATABASE'] ?? 'modular_api_graphql_v1',
      username: env['MODULAR_API_SQLSERVER_USERNAME'] ?? 'sa',
      password: env['MODULAR_API_SQLSERVER_PASSWORD'] ?? 'ModularApi_dev_StrongPass1',
      driver: env['MODULAR_API_SQLSERVER_DRIVER'] ?? 'ODBC Driver 17 for SQL Server',
    );
  }

  final String host;
  final int port;
  final String database;
  final String username;
  final String password;
  final String driver;
}