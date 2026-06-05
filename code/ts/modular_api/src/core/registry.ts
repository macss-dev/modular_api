// ============================================================
// core/registry.ts
// In-memory registry of all registered use cases.
// Used by the OpenAPI generator to build the spec automatically.
// Mirror of _ApiRegistry + UseCaseRegistration in Dart.
// ============================================================

import type { UseCaseFactory } from './usecase';
import type { Input, Output } from './usecase';

export interface UseCaseDocMeta {
  summary?: string;
  description?: string;
  /** Tags for Swagger grouping — typically the module name */
  tags?: string[];
  /** Override for the Input JSON Schema (captured at registration time) */
  inputSchema?: Record<string, unknown>;
  /** Override for the Output JSON Schema (captured at registration time) */
  outputSchema?: Record<string, unknown>;
}

export interface UseCaseRegistration {
  module: string;
  /** Route segment and operationId root, e.g. 'hello-world' */
  command: string;
  /** HTTP method in uppercase: "POST" | "GET" | "PUT" | "PATCH" | "DELETE" */
  method: string;
  /** Full path e.g. "/api/v1/greetings/hello-world" */
  path: string;
  factory: UseCaseFactory<Input, Output>;
  doc?: UseCaseDocMeta;
  /** Schemas captured at registration time via dummy factory call */
  schemas: {
    input: Record<string, unknown>;
    output: Record<string, unknown>;
  };
}

/**
 * Singleton registry — holds all registered routes for OpenAPI generation.
 * Populated by ModuleBuilder.usecase() at startup.
 */
class ApiRegistry {
  readonly routes: UseCaseRegistration[] = [];

  clear(): void {
    this.routes.length = 0;
  }
}

export const apiRegistry = new ApiRegistry();
