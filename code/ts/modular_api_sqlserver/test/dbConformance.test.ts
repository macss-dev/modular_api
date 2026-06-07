import { readFileSync } from 'node:fs';
import { resolve } from 'node:path';

import { describe, expect, it } from 'vitest';

import {
  DbConnectionSettings,
  DbFailure,
  DbFailureKind,
  DbResult,
} from '../src';

type Fixture = {
  connection: {
    environment: Record<string, string>;
    expected: {
      engineId: string;
      host: string;
      port: number;
      database: string;
      username: string;
      password: string;
      driver: string;
    };
    redactedContains: string[];
    redactedExcludes: string[];
  };
  result: {
    successValue: number;
    mappedValue: number;
    flatMappedValue: number;
    timeoutCode: string;
    wrappedFailureCode: string;
  };
};

const fixture = JSON.parse(
  readFileSync(resolve(process.cwd(), '../../tests/fixtures/db_client/sqlserver.json'), 'utf8'),
) as Fixture;

describe('db conformance', () => {
  it('matches the shared SQL Server connection fixture', () => {
    const settings = DbConnectionSettings.fromEnvironment(fixture.connection.environment);

    expect(settings.engineId).toBe(fixture.connection.expected.engineId);
    expect(settings.host).toBe(fixture.connection.expected.host);
    expect(settings.port).toBe(fixture.connection.expected.port);
    expect(settings.database).toBe(fixture.connection.expected.database);
    expect(settings.username).toBe(fixture.connection.expected.username);
    expect(settings.password).toBe(fixture.connection.expected.password);
    expect(settings.driver).toBe(fixture.connection.expected.driver);

    for (const fragment of fixture.connection.redactedContains) {
      expect(settings.redactedSummary).toContain(fragment);
    }
    for (const fragment of fixture.connection.redactedExcludes) {
      expect(settings.redactedSummary).not.toContain(fragment);
    }
  });

  it('matches the shared DbResult fixture', () => {
    const success = DbResult.success(fixture.result.successValue);
    const failure = DbResult.failure<number>(
      new DbFailure({
        kind: DbFailureKind.timeout,
        code: fixture.result.timeoutCode,
        message: 'Timed out',
        retryable: true,
        transient: true,
      }),
    );

    expect(success.map((value) => value * 2).value).toBe(fixture.result.mappedValue);
    expect(success.flatMap((value) => DbResult.success(value + 1)).value).toBe(
      fixture.result.flatMappedValue,
    );

    const mappedFailure = failure.mapFailure(
      (current) =>
        new DbFailure({
          kind: current.kind,
          code: fixture.result.wrappedFailureCode,
          message: current.message,
          retryable: current.retryable,
          transient: current.transient,
        }),
    );

    expect(mappedFailure.failure.code).toBe(fixture.result.wrappedFailureCode);
  });
});