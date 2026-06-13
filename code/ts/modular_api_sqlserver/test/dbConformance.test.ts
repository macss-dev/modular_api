import { readFileSync } from 'node:fs';
import { resolve } from 'node:path';

import { describe, expect, it } from 'vitest';

import {
  DbCommand,
  DbCommandKind,
  DbConnectionSettings,
  DbFailure,
  DbFailureKind,
  DbParameter,
  DbProcedureOutcome,
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
  command: {
    procedureName: string;
    inputParameter: { name: string; value: number; typeHint: string; expectedDirection: string };
    outputParameter: { name: string; typeHint: string; expectedDirection: string };
    outcome: { returnValue: number; outputParameterName: string; outputParameterValue: number };
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

  it('matches the shared typed-parameter and stored-procedure fixture (0.6.0)', () => {
    const input = DbParameter.input(
      fixture.command.inputParameter.name,
      fixture.command.inputParameter.value,
      fixture.command.inputParameter.typeHint,
    );
    expect(input.name).toBe(fixture.command.inputParameter.name);
    expect(input.value).toBe(fixture.command.inputParameter.value);
    expect(input.typeHint).toBe(fixture.command.inputParameter.typeHint);
    expect(String(input.direction)).toBe(fixture.command.inputParameter.expectedDirection);

    const output = DbParameter.output(
      fixture.command.outputParameter.name,
      fixture.command.outputParameter.typeHint,
    );
    expect(output.value).toBeUndefined();
    expect(String(output.direction)).toBe(fixture.command.outputParameter.expectedDirection);

    const command = new DbCommand({
      kind: DbCommandKind.procedure,
      text: fixture.command.procedureName,
      parameters: [input],
    });
    expect(String(command.kind)).toBe('procedure');
    expect(command.text).toBe(fixture.command.procedureName);
    expect(command.parameters[0]).toBeInstanceOf(DbParameter);

    const outcome = new DbProcedureOutcome({
      returnValue: fixture.command.outcome.returnValue,
      outputParameters: {
        [fixture.command.outcome.outputParameterName]: fixture.command.outcome.outputParameterValue,
      },
    });
    expect(outcome.returnValue).toBe(fixture.command.outcome.returnValue);
    expect(outcome.outputParameters?.[fixture.command.outcome.outputParameterName]).toBe(
      fixture.command.outcome.outputParameterValue,
    );
  });
});