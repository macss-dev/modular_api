import 'package:modular_api/modular_api.dart';
import '../../db/db_client.dart';

/// Simple repository that exposes two database clients
/// and concrete methods to fetch data.
class HelloWorldRepository {
  final DbClient _oracle;
  final DbClient _sqlserver;

  HelloWorldRepository({DbClient? oracle, DbClient? sqlserver})
    : _oracle = oracle ?? createOracleClient(),
      _sqlserver = sqlserver ?? createSqlServerClient();

  Future<String> helloOracle() async {
    try {
      final rows = await _oracle.execute('SELECT BANNER FROM v\$version');
      return rows.toString();
    } catch (e) {
      return 'Oracle query error: $e';
    }
  }

  Future<String> helloSqlserver() async {
    try {
      final rows = await _sqlserver.execute('SELECT @@VERSION as version');

      return rows.toString();
    } catch (e) {
      return 'SQL Server query error: $e';
    }
  }
}
