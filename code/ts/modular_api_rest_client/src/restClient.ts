export type ServiceDecoder<T> = (value: unknown) => T;
export type ServiceAuthProvider = (
  operation: ServiceOperation,
) => Record<string, string> | Promise<Record<string, string>>;

export class ServiceClientConfig {
  public readonly serviceId: string;
  public readonly baseUrl: URL;
  public readonly redactedSummary: string;
  public readonly defaultHeaders: Record<string, string>;
  public readonly authProvider?: ServiceAuthProvider;
  public readonly timeout?: number;
  public readonly retryPolicy?: ServiceRetryPolicy;
  public readonly userAgent?: string;
  public readonly telemetryHooks?: ServiceTelemetryHooks;

  public constructor(options: {
    serviceId: string;
    baseUrl: string | URL;
    redactedSummary: string;
    defaultHeaders?: Record<string, string>;
    authProvider?: ServiceAuthProvider;
    timeout?: number;
    retryPolicy?: ServiceRetryPolicy;
    userAgent?: string;
    telemetryHooks?: ServiceTelemetryHooks;
  }) {
    this.serviceId = options.serviceId;
    this.baseUrl = options.baseUrl instanceof URL ? options.baseUrl : new URL(options.baseUrl);
    this.redactedSummary = options.redactedSummary;
    this.defaultHeaders = { ...(options.defaultHeaders ?? {}) };
    this.authProvider = options.authProvider;
    this.timeout = options.timeout;
    this.retryPolicy = options.retryPolicy;
    this.userAgent = options.userAgent;
    this.telemetryHooks = options.telemetryHooks;
  }
}

export class ServiceRetryPolicy {
  public readonly maxAttempts: number;

  public constructor(options: { maxAttempts?: number } = {}) {
    this.maxAttempts = options.maxAttempts ?? 1;
  }
}

export class ServiceTelemetryHooks {
  public readonly onStarted?: (operation: ServiceOperation) => void;
  public readonly onCompleted?: (
    operation: ServiceOperation,
    result: ServiceResult<unknown>,
  ) => void;

  public constructor(options: {
    onStarted?: (operation: ServiceOperation) => void;
    onCompleted?: (operation: ServiceOperation, result: ServiceResult<unknown>) => void;
  } = {}) {
    this.onStarted = options.onStarted;
    this.onCompleted = options.onCompleted;
  }
}

export class ServiceOperation {
  public readonly transportId: string;
  public readonly operationId: string;
  public readonly headers: Record<string, string>;
  public readonly method?: string;
  public readonly path?: string;
  public readonly query?: Record<string, unknown>;
  public readonly body?: unknown;
  public readonly document?: string;
  public readonly variables?: Record<string, unknown>;
  public readonly operationName?: string;

  public constructor(options: {
    transportId: string;
    operationId: string;
    headers?: Record<string, string>;
    method?: string;
    path?: string;
    query?: Record<string, unknown>;
    body?: unknown;
    document?: string;
    variables?: Record<string, unknown>;
    operationName?: string;
  }) {
    this.transportId = options.transportId;
    this.operationId = options.operationId;
    this.headers = { ...(options.headers ?? {}) };
    this.method = options.method;
    this.path = options.path;
    this.query = options.query;
    this.body = options.body;
    this.document = options.document;
    this.variables = options.variables;
    this.operationName = options.operationName;
  }
}

export class ServiceRequest extends ServiceOperation {
  public constructor(options: {
    operationId: string;
    method: string;
    path: string;
    headers?: Record<string, string>;
    query?: Record<string, unknown>;
    body?: unknown;
  }) {
    super({
      transportId: 'http',
      operationId: options.operationId,
      method: options.method,
      path: options.path,
      headers: options.headers,
      query: options.query,
      body: options.body,
    });
  }
}

export class ServiceResponseMetadata {
  public readonly statusCode: number;
  public readonly headers: Record<string, string>;
  public readonly transportId: string;
  public readonly duration: number;
  public readonly requestId?: string;

  public constructor(options: {
    statusCode: number;
    headers: Record<string, string>;
    transportId: string;
    duration: number;
    requestId?: string;
  }) {
    this.statusCode = options.statusCode;
    this.headers = options.headers;
    this.transportId = options.transportId;
    this.duration = options.duration;
    this.requestId = options.requestId;
  }
}

export class ServiceResponse<T> {
  public readonly data: T;
  public readonly metadata: ServiceResponseMetadata;

  public constructor(options: { data: T; metadata: ServiceResponseMetadata }) {
    this.data = options.data;
    this.metadata = options.metadata;
  }
}

export enum ServiceFailureCategory {
  transport = 'transport',
  timeout = 'timeout',
  auth = 'auth',
  rateLimit = 'rate_limit',
  protocol = 'protocol',
  decode = 'decode',
  graphql = 'graphql',
  unexpected = 'unexpected',
}

export class ServiceFailure {
  public readonly category: ServiceFailureCategory;
  public readonly code: string;
  public readonly message: string;
  public readonly retryable: boolean;
  public readonly statusCode?: number;
  public readonly transportId?: string;
  public readonly details?: unknown;
  public readonly causeSummary?: string;

  public constructor(options: {
    category: ServiceFailureCategory;
    code: string;
    message: string;
    retryable: boolean;
    statusCode?: number;
    transportId?: string;
    details?: unknown;
    causeSummary?: string;
  }) {
    this.category = options.category;
    this.code = options.code;
    this.message = options.message;
    this.retryable = options.retryable;
    this.statusCode = options.statusCode;
    this.transportId = options.transportId;
    this.details = options.details;
    this.causeSummary = options.causeSummary;
  }
}

export class ServiceResult<T> {
  private readonly innerValue?: T;
  private readonly innerFailure?: ServiceFailure;

  private constructor(value?: T, failure?: ServiceFailure) {
    this.innerValue = value;
    this.innerFailure = failure;
  }

  public static success<T>(value: T): ServiceResult<T> {
    return new ServiceResult<T>(value, undefined);
  }

  public static failure<T>(failure: ServiceFailure): ServiceResult<T> {
    return new ServiceResult<T>(undefined, failure);
  }

  public get isSuccess(): boolean {
    return this.innerFailure === undefined;
  }

  public get isFailure(): boolean {
    return this.innerFailure !== undefined;
  }

  public get value(): T {
    if (this.innerValue === undefined) {
      throw new Error('ServiceResult does not contain a success value.');
    }
    return this.innerValue;
  }

  public get failure(): ServiceFailure {
    if (this.innerFailure === undefined) {
      throw new Error('ServiceResult does not contain a failure value.');
    }
    return this.innerFailure;
  }
}

export class ServiceClientDescription {
  public readonly serviceId: string;
  public readonly transportId: string;
  public readonly baseUrl: URL;
  public readonly redactedSummary: string;

  public constructor(options: {
    serviceId: string;
    transportId: string;
    baseUrl: URL;
    redactedSummary: string;
  }) {
    this.serviceId = options.serviceId;
    this.transportId = options.transportId;
    this.baseUrl = options.baseUrl;
    this.redactedSummary = options.redactedSummary;
  }
}

export interface ServiceClient {
  execute<T>(
    operation: ServiceOperation,
    options?: { decoder?: ServiceDecoder<T> },
  ): Promise<ServiceResult<ServiceResponse<T>>>;

  close(): Promise<ServiceResult<void>>;

  describe(): ServiceClientDescription;
}

export class HttpServiceClient implements ServiceClient {
  private readonly config: ServiceClientConfig;
  private readonly fetchImpl: typeof fetch;
  private closed = false;

  public constructor(config: ServiceClientConfig, options: { fetchImpl?: typeof fetch } = {}) {
    this.config = config;
    this.fetchImpl = options.fetchImpl ?? fetch;
  }

  public describe(): ServiceClientDescription {
    return new ServiceClientDescription({
      serviceId: this.config.serviceId,
      transportId: 'http',
      baseUrl: this.config.baseUrl,
      redactedSummary: this.config.redactedSummary,
    });
  }

  public async execute<T>(
    operation: ServiceOperation,
    options: { decoder?: ServiceDecoder<T> } = {},
  ): Promise<ServiceResult<ServiceResponse<T>>> {
    if (this.closed) {
      return ServiceResult.failure(
        new ServiceFailure({
          category: ServiceFailureCategory.unexpected,
          code: 'client_closed',
          message: 'The HTTP service client is already closed.',
          retryable: false,
          transportId: 'http',
        }),
      );
    }

    if (operation.transportId !== 'http' || !operation.method || !operation.path) {
      return ServiceResult.failure(
        new ServiceFailure({
          category: ServiceFailureCategory.protocol,
          code: 'invalid_operation',
          message: 'HTTP execution requires transportId, method, and path.',
          retryable: false,
          transportId: 'http',
        }),
      );
    }

    this.config.telemetryHooks?.onStarted?.(operation);

    const headers: Record<string, string> = {
      ...this.config.defaultHeaders,
      ...operation.headers,
    };
    if (this.config.authProvider) {
      Object.assign(headers, await this.config.authProvider(operation));
    }
    if (this.config.userAgent && headers['user-agent'] === undefined) {
      headers['user-agent'] = this.config.userAgent;
    }

    const url = resolveUrl(this.config.baseUrl, operation.path, operation.query);
    const startedAt = performance.now();
    const controller = new AbortController();
    const timeoutHandle =
      this.config.timeout === undefined
        ? undefined
        : setTimeout(() => controller.abort(), this.config.timeout);

    try {
      const response = await this.fetchImpl(url, {
        method: operation.method,
        headers,
        body: operation.body === undefined ? undefined : JSON.stringify(operation.body),
        signal: controller.signal,
      });
      const text = await response.text();
      const elapsed = performance.now() - startedAt;
      const headerMap = flattenHeaders(response.headers);

      if (!response.ok) {
        return ServiceResult.failure(
          new ServiceFailure({
            category: categoryForStatus(response.status),
            code: codeForStatus(response.status),
            message: text.length > 0 ? text : `HTTP request failed with status ${response.status}.`,
            retryable: isRetryableStatus(response.status),
            statusCode: response.status,
            transportId: 'http',
            details: text.length > 0 ? text : undefined,
          }),
        );
      }

      const decoded = decodeBody<T>(text, response.headers.get('content-type'), options.decoder);
      if (decoded instanceof ServiceFailure) {
        return ServiceResult.failure(decoded);
      }

      return ServiceResult.success(
        new ServiceResponse({
          data: decoded,
          metadata: new ServiceResponseMetadata({
            statusCode: response.status,
            headers: headerMap,
            transportId: 'http',
            duration: elapsed,
            requestId: headerMap['x-request-id'],
          }),
        }),
      );
    } catch (error) {
      if (controller.signal.aborted || isAbortError(error)) {
        return ServiceResult.failure(
          new ServiceFailure({
            category: ServiceFailureCategory.timeout,
            code: 'timeout',
            message: 'The HTTP request timed out.',
            retryable: true,
            transportId: 'http',
          }),
        );
      }

      if (error instanceof SyntaxError) {
        return ServiceResult.failure(
          new ServiceFailure({
            category: ServiceFailureCategory.decode,
            code: 'invalid_json',
            message: 'The HTTP response body is not valid JSON.',
            retryable: false,
            transportId: 'http',
            causeSummary: error.message,
          }),
        );
      }

      return ServiceResult.failure(
        new ServiceFailure({
          category: ServiceFailureCategory.transport,
          code: 'transport_error',
          message: 'The HTTP request failed to reach the remote service.',
          retryable: true,
          transportId: 'http',
          causeSummary: error instanceof Error ? error.message : String(error),
        }),
      );
    } finally {
      if (timeoutHandle !== undefined) {
        clearTimeout(timeoutHandle);
      }
      this.config.telemetryHooks?.onCompleted?.(
        operation,
        ServiceResult.success<unknown>(undefined),
      );
    }
  }

  public async close(): Promise<ServiceResult<void>> {
    this.closed = true;
    return ServiceResult.success(undefined);
  }
}

export async function httpClient<T>(options: {
  config: ServiceClientConfig;
  request: ServiceRequest;
  decoder?: ServiceDecoder<T>;
}): Promise<ServiceResult<ServiceResponse<T>>> {
  const client = new HttpServiceClient(options.config);
  try {
    return await client.execute(options.request, { decoder: options.decoder });
  } finally {
    await client.close();
  }
}

function resolveUrl(baseUrl: URL, path: string, query?: Record<string, unknown>): URL {
  const normalizedPath = path.startsWith('/') ? path.slice(1) : path;
  const url = new URL(baseUrl.toString());
  url.pathname = joinPath(url.pathname, normalizedPath);
  url.search = '';

  if (query !== undefined) {
    for (const [key, value] of Object.entries(query)) {
      if (value !== undefined && value !== null) {
        url.searchParams.set(key, String(value));
      }
    }
  }

  return url;
}

function joinPath(basePath: string, nextPath: string): string {
  const baseSegments = basePath.split('/').filter((segment) => segment.length > 0);
  const nextSegments = nextPath.split('/').filter((segment) => segment.length > 0);
  return `/${[...baseSegments, ...nextSegments].join('/')}`;
}

function flattenHeaders(headers: Headers): Record<string, string> {
  const result: Record<string, string> = {};
  headers.forEach((value, key) => {
    result[key] = value;
  });
  return result;
}

function decodeBody<T>(
  body: string,
  contentType: string | null,
  decoder?: ServiceDecoder<T>,
): T | ServiceFailure {
  let decoded: unknown;
  if (body.length === 0) {
    decoded = undefined;
  } else if (looksLikeJson(contentType, body)) {
    try {
      decoded = JSON.parse(body) as unknown;
    } catch (error) {
      return new ServiceFailure({
        category: ServiceFailureCategory.decode,
        code: 'invalid_json',
        message: 'The HTTP response body is not valid JSON.',
        retryable: false,
        transportId: 'http',
        causeSummary: error instanceof Error ? error.message : String(error),
      });
    }
  } else {
    decoded = body;
  }

  return decoder ? decoder(decoded) : (decoded as T);
}

function looksLikeJson(contentType: string | null, body: string): boolean {
  if (contentType !== null) {
    const normalized = contentType.toLowerCase();
    if (normalized.startsWith('application/json') || normalized.includes('+json')) {
      return true;
    }
  }
  const trimmed = body.trimStart();
  return trimmed.startsWith('{') || trimmed.startsWith('[');
}

function categoryForStatus(statusCode: number): ServiceFailureCategory {
  if (statusCode === 401 || statusCode === 403) {
    return ServiceFailureCategory.auth;
  }
  if (statusCode === 429) {
    return ServiceFailureCategory.rateLimit;
  }
  return ServiceFailureCategory.protocol;
}

function codeForStatus(statusCode: number): string {
  if (statusCode === 401) {
    return 'unauthorized';
  }
  if (statusCode === 403) {
    return 'forbidden';
  }
  if (statusCode === 429) {
    return 'rate_limit';
  }
  return `http_${statusCode}`;
}

function isRetryableStatus(statusCode: number): boolean {
  return statusCode === 429 || statusCode >= 500;
}

function isAbortError(error: unknown): boolean {
  return error instanceof DOMException
    ? error.name === 'AbortError'
    : error instanceof Error && error.name === 'AbortError';
}