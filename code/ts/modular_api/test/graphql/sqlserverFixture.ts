/**
 * Shared gating for the SQL Server smoke tests.
 *
 * Start the fixture with `docker compose up -d` in `code/infra/docker`; the
 * defaults below already match that container (`127.0.0.1:14333`).
 *
 * These tests are the only ones in the ecosystem that need external
 * infrastructure, and when it is absent they must **skip**, not fail: a suite
 * that reports failures for missing infrastructure trains the reader to ignore
 * a red result, which is exactly how a genuine regression hides.
 *
 * Gating on driver resolution alone — the previous approach — was luck rather
 * than design: it only passed because `mssql` is not installed here. On a
 * machine where the driver IS present, the suite would fail at `sql.connect`.
 * The gate is therefore driver resolution **and** reachability, matching the
 * reachability probe the Python SDK uses in its `conftest.py` and the
 * `setUpAll` probe the Dart SDK uses.
 *
 * The probe runs once per module load, so an unavailable server costs one
 * connection attempt rather than one per test.
 */
import { createRequire } from 'node:module';

const require = createRequire(import.meta.url);

export type SqlRequestLike = {
  query<Row extends object>(query: string): Promise<{ recordset: Row[] }>;
};

export type SqlConnectionPoolLike = {
  close(): Promise<void>;
  request(): SqlRequestLike;
};

export type SqlModuleLike = {
  connect(config: object): Promise<SqlConnectionPoolLike>;
};

export const sqlServerConfig = {
  user: process.env.MODULAR_API_SQLSERVER_USERNAME ?? 'sa',
  password: process.env.MODULAR_API_SQLSERVER_PASSWORD ?? 'ModularApi_dev_StrongPass1',
  server: process.env.MODULAR_API_SQLSERVER_HOST ?? '127.0.0.1',
  port: Number.parseInt(process.env.MODULAR_API_SQLSERVER_PORT ?? '14333', 10),
  database: process.env.MODULAR_API_SQLSERVER_DATABASE ?? 'modular_api_graphql_v1',
  options: {
    encrypt: false,
    trustServerCertificate: true,
  },
};

export const hasSqlDriver = ((): boolean => {
  try {
    require.resolve('mssql');
    return true;
  } catch {
    return false;
  }
})();

export const loadSqlModule = (): SqlModuleLike => require('mssql') as SqlModuleLike;

/** Why the fixture cannot be used, or `null` when it can. Probed once. */
export const sqlServerUnavailableReason: string | null = await (async () => {
  if (!hasSqlDriver) {
    return 'the optional mssql driver is not installed';
  }
  try {
    const pool = await loadSqlModule().connect(sqlServerConfig);
    await pool.close();
    return null;
  } catch (error) {
    const detail = error instanceof Error ? error.message : String(error);
    return (
      `SQL Server fixture is not reachable (${detail}). Start it with ` +
      '`docker compose up -d` in code/infra/docker, or set MODULAR_API_SQLSERVER_* ' +
      'to a live instance.'
    );
  }
})();

export const sqlServerAvailable = sqlServerUnavailableReason === null;
