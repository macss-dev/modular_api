import {
  HttpServiceClient,
  ServiceClientConfig,
  ServiceClientDescription,
  ServiceFailure,
  ServiceFailureCategory,
  ServiceRequest,
  ServiceResponseMetadata,
  ServiceResult,
} from '@macss/modular-api-rest-client';

export type GraphqlDecoder<T> = (value: unknown) => T;

export class GraphqlRequest {
  public readonly operationId: string;
  public readonly document: string;
  public readonly headers: Record<string, string>;
  public readonly variables?: Record<string, unknown>;
  public readonly operationName?: string;
  public readonly path: string;

  public constructor(options: {
    operationId: string;
    document: string;
    headers?: Record<string, string>;
    variables?: Record<string, unknown>;
    operationName?: string;
    path?: string;
  }) {
    this.operationId = options.operationId;
    this.document = options.document;
    this.headers = { ...(options.headers ?? {}) };
    this.variables = options.variables;
    this.operationName = options.operationName;
    this.path = options.path ?? '/graphql';
  }
}

export class GraphqlErrorLocation {
  public readonly line: number;
  public readonly column: number;

  public constructor(options: { line: number; column: number }) {
    this.line = options.line;
    this.column = options.column;
  }
}

export class GraphqlError {
  public readonly message: string;
  public readonly path: unknown[];
  public readonly locations: GraphqlErrorLocation[];
  public readonly extensions?: Record<string, unknown>;

  public constructor(options: {
    message: string;
    path?: unknown[];
    locations?: GraphqlErrorLocation[];
    extensions?: Record<string, unknown>;
  }) {
    this.message = options.message;
    this.path = [...(options.path ?? [])];
    this.locations = [...(options.locations ?? [])];
    this.extensions = options.extensions;
  }
}

export class GraphqlResponse<T> {
  public readonly data: T | null;
  public readonly errors: GraphqlError[];
  public readonly extensions?: Record<string, unknown>;
  public readonly metadata: ServiceResponseMetadata;

  public constructor(options: {
    data: T | null;
    errors: GraphqlError[];
    extensions?: Record<string, unknown>;
    metadata: ServiceResponseMetadata;
  }) {
    this.data = options.data;
    this.errors = [...options.errors];
    this.extensions = options.extensions;
    this.metadata = options.metadata;
  }
}

export class GraphqlClient {
  private readonly httpClient: HttpServiceClient;
  private readonly ownsHttpClient: boolean;

  public constructor(
    public readonly config: ServiceClientConfig,
    options: { httpClient?: HttpServiceClient } = {},
  ) {
    this.httpClient = options.httpClient ?? new HttpServiceClient(config);
    this.ownsHttpClient = options.httpClient === undefined;
  }

  public describe(): ServiceClientDescription {
    return new ServiceClientDescription({
      serviceId: this.config.serviceId,
      transportId: 'graphql',
      baseUrl: this.config.baseUrl,
      redactedSummary: this.config.redactedSummary,
    });
  }

  public async execute<T>(
    request: GraphqlRequest,
    options: { decoder?: GraphqlDecoder<T> } = {},
  ): Promise<ServiceResult<GraphqlResponse<T>>> {
    if (isMutationDocument(request.document)) {
      return ServiceResult.failure(
        new ServiceFailure({
          category: ServiceFailureCategory.graphql,
          code: 'mutation_not_supported',
          message: 'GraphQL mutations are not supported in v1.',
          retryable: false,
          transportId: 'graphql',
        }),
      );
    }

    const transportResult = await this.httpClient.execute<Record<string, unknown>>(
      new ServiceRequest({
        operationId: request.operationId,
        method: 'POST',
        path: request.path,
        headers: request.headers,
        body: {
          query: request.document,
          ...(request.variables === undefined ? {} : { variables: request.variables }),
          ...(request.operationName === undefined
            ? {}
            : { operationName: request.operationName }),
        },
      }),
      {
        decoder: (value) => {
          if (!isRecord(value)) {
            throw new Error('GraphQL response must be a JSON object.');
          }
          return value;
        },
      },
    );

    if (transportResult.isFailure) {
      return ServiceResult.failure(transportResult.failure);
    }

    const envelope = transportResult.value.data;
    const rawData = envelope.data ?? null;
    const decodedData = decodeData(rawData, options.decoder);
    if (decodedData instanceof ServiceFailure) {
      return ServiceResult.failure(decodedData);
    }

    return ServiceResult.success(
      new GraphqlResponse<T>({
        data: decodedData as T | null,
        errors: parseErrors(envelope.errors),
        extensions: isRecord(envelope.extensions) ? envelope.extensions : undefined,
        metadata: new ServiceResponseMetadata({
          statusCode: transportResult.value.metadata.statusCode,
          headers: transportResult.value.metadata.headers,
          transportId: 'graphql',
          duration: transportResult.value.metadata.duration,
          requestId: transportResult.value.metadata.requestId,
        }),
      }),
    );
  }

  public async close(): Promise<ServiceResult<void>> {
    if (!this.ownsHttpClient) {
      return ServiceResult.success<void>(undefined);
    }

    return this.httpClient.close();
  }
}

export async function graphqlClient<T>(options: {
  config: ServiceClientConfig;
  request: GraphqlRequest;
  decoder?: GraphqlDecoder<T>;
}): Promise<ServiceResult<GraphqlResponse<T>>> {
  const client = new GraphqlClient(options.config);
  try {
    return await client.execute<T>(options.request, { decoder: options.decoder });
  } finally {
    await client.close();
  }
}

function isMutationDocument(document: string): boolean {
  return /^\s*mutation\b/.test(document);
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === 'object' && value !== null && !Array.isArray(value);
}

function parseErrors(value: unknown): GraphqlError[] {
  if (!Array.isArray(value)) {
    return [];
  }

  return value.map((entry) => {
    const error = isRecord(entry) ? entry : {};
    const locations = Array.isArray(error.locations)
      ? error.locations
          .filter(isRecord)
          .map(
            (location) =>
              new GraphqlErrorLocation({
                line: typeof location.line === 'number' ? location.line : 0,
                column: typeof location.column === 'number' ? location.column : 0,
              }),
          )
      : [];

    return new GraphqlError({
      message: typeof error.message === 'string' ? error.message : 'Unknown GraphQL error',
      path: Array.isArray(error.path) ? [...error.path] : [],
      locations,
      extensions: isRecord(error.extensions) ? error.extensions : undefined,
    });
  });
}

function decodeData<T>(
  value: unknown,
  decoder?: GraphqlDecoder<T>,
): T | null | ServiceFailure {
  if (decoder === undefined) {
    return value as T | null;
  }

  try {
    return decoder(value);
  } catch (error: unknown) {
    return new ServiceFailure({
      category: ServiceFailureCategory.decode,
      code: 'invalid_graphql_data',
      message: 'The GraphQL response data could not be decoded.',
      retryable: false,
      transportId: 'graphql',
      causeSummary: error instanceof Error ? error.message : String(error),
    });
  }
}