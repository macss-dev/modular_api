export class SqlServerConnectionSettings {
  readonly host: string;
  readonly port: number;
  readonly database: string;
  readonly username: string;
  readonly password: string;

  constructor(options: {
    host: string;
    port: number;
    database: string;
    username: string;
    password: string;
  }) {
    this.host = options.host;
    this.port = options.port;
    this.database = options.database;
    this.username = options.username;
    this.password = options.password;
  }

  static fromEnvironment(environment: NodeJS.ProcessEnv = process.env): SqlServerConnectionSettings {
    const parsedPort = Number.parseInt(environment.MODULAR_API_SQLSERVER_PORT ?? '', 10);

    return new SqlServerConnectionSettings({
      host: environment.MODULAR_API_SQLSERVER_HOST ?? '127.0.0.1',
      port: Number.isNaN(parsedPort) ? 14333 : parsedPort,
      database: environment.MODULAR_API_SQLSERVER_DATABASE ?? 'modular_api_graphql_v1',
      username: environment.MODULAR_API_SQLSERVER_USERNAME ?? 'sa',
      password: environment.MODULAR_API_SQLSERVER_PASSWORD ?? 'ModularApi_dev_StrongPass1',
    });
  }
}