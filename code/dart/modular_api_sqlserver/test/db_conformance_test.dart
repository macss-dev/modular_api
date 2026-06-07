import 'dart:convert';
import 'dart:io';

import 'package:modular_api_sqlserver/modular_api_sqlserver.dart';
import 'package:test/test.dart';

void main() {
  final fixture = jsonDecode(
        File('../../tests/fixtures/db_client/sqlserver.json').readAsStringSync(),
      )
      as Map<String, Object?>;
  final connection = fixture['connection'] as Map<String, Object?>;
  final expected = connection['expected'] as Map<String, Object?>;
  final resultFixture = fixture['result'] as Map<String, Object?>;

  test('matches the shared SQL Server connection fixture', () {
    final environment = (connection['environment'] as Map<String, Object?>).map(
      (key, value) => MapEntry(key, value as String),
    );
    final settings = DbConnectionSettings.fromEnvironment(environment: environment);

    expect(settings.engineId, expected['engineId']);
    expect(settings.host, expected['host']);
    expect(settings.port, expected['port']);
    expect(settings.database, expected['database']);
    expect(settings.username, expected['username']);
    expect(settings.password, expected['password']);
    expect(settings.driver, expected['driver']);

    for (final fragment in connection['redactedContains'] as List<Object?>) {
      expect(settings.redactedSummary, contains(fragment));
    }
    for (final fragment in connection['redactedExcludes'] as List<Object?>) {
      expect(settings.redactedSummary, isNot(contains(fragment)));
    }
  });

  test('matches the shared DbResult fixture', () {
    final successValue = resultFixture['successValue'] as int;
    final success = DbResult<int>.success(successValue);
    final failure = DbResult<int>.failure(
      DbFailure(
        kind: DbFailureKind.timeout,
        code: resultFixture['timeoutCode'] as String,
        message: 'Timed out',
        retryable: true,
        transient: true,
      ),
    );

    expect(success.map((value) => value * 2).value, resultFixture['mappedValue']);
    expect(
      success.flatMap((value) => DbResult<int>.success(value + 1)).value,
      resultFixture['flatMappedValue'],
    );

    final mappedFailure = failure.mapFailure(
      (current) => DbFailure(
        kind: current.kind,
        code: resultFixture['wrappedFailureCode'] as String,
        message: current.message,
        retryable: current.retryable,
        transient: current.transient,
      ),
    );

    expect(mappedFailure.failure.code, resultFixture['wrappedFailureCode']);
  });
}