import type { TextMapPropagator, Tracer, TracerProvider } from '@opentelemetry/api';

import type { TraceFieldFormatter } from '../logger/logger';
import { PropagationPolicy } from './propagationPolicy';

export interface TracingOptionsInit {
  /** The application's tracer provider, from its OpenTelemetry SDK. */
  readonly tracerProvider: TracerProvider;

  /**
   * The ordered propagator chain. Defaults to W3C Trace Context alone.
   *
   * A service on Google Cloud appends a Cloud Trace propagator, which is how
   * vendor-specific formats stay out of the framework (runbook D24, roadmap
   * invariant 7).
   */
  readonly propagators?: readonly TextMapPropagator<unknown>[];

  /**
   * Whether an incoming trace context is honoured at all. Defaults to `true`.
   *
   * **Set it to `false` on a service that receives internet traffic directly**,
   * where a caller could otherwise choose its own trace ids and collide traces
   * (runbook D25).
   */
  readonly trustIncomingTraceContext?: boolean;

  /** The instrumentation scope name reported to the backend. */
  readonly instrumentationName?: string;

  /**
   * Builds platform-specific log correlation fields, or undefined for none.
   *
   * The framework emits open formats and nothing vendor-specific (roadmap invariant 7),
   * so a field like Google's `logging.googleapis.com/trace` — which needs a project id
   * the framework has no business knowing — is produced here by the application.
   */
  readonly traceFieldFormatter?: TraceFieldFormatter;

  /**
   * Runs when the server closes, before the process goes away.
   *
   * **The framework offers the timing; the application decides what it means.** On a
   * scale-to-zero platform this is the only window to flush queued spans before the
   * container dies — but the provider belongs to the application, which may share it with
   * a worker or a scheduled job still running. Tearing down a resource the framework did
   * not create would be presumptuous, and `TracerProvider` in `@opentelemetry/api`
   * exposes no shutdown at all: only `getTracer` (runbook D8 as revised).
   *
   * ```ts
   * onShutdown: () => provider.shutdown(),
   * ```
   *
   * A callback that rejects is swallowed: losing telemetry is bad, failing to stop the
   * server is worse.
   */
  readonly onShutdown?: () => Promise<void>;
}

/**
 * Turns tracing on and says how.
 *
 * **Absent means off, and off is free.** Without this, no tracing middleware is
 * installed, no span is ever created, and the log format is unchanged. A REST-only
 * API that never asks for tracing behaves exactly as it did before (ADR-0005
 * invariant 3, gate G3).
 *
 * **The application supplies the tracer, not the framework** (ADR-0005 A2). Core
 * depends on `@opentelemetry/api`; the SDK, its exporters and any credentials belong
 * to the application, which builds a provider and passes it here.
 */
export class TracingOptions {
  readonly tracerProvider: TracerProvider;
  readonly trustIncomingTraceContext: boolean;
  readonly instrumentationName: string;
  readonly traceFieldFormatter?: TraceFieldFormatter;
  readonly onShutdown?: () => Promise<void>;
  private readonly propagators?: readonly TextMapPropagator<unknown>[];

  constructor(init: TracingOptionsInit) {
    this.tracerProvider = init.tracerProvider;
    this.propagators = init.propagators;
    this.trustIncomingTraceContext = init.trustIncomingTraceContext ?? true;
    this.instrumentationName = init.instrumentationName ?? 'modular_api';
    this.traceFieldFormatter = init.traceFieldFormatter;
    this.onShutdown = init.onShutdown;
  }

  /** The propagation policy these options describe. */
  get policy(): PropagationPolicy {
    return new PropagationPolicy({
      ...(this.propagators === undefined ? {} : { propagators: this.propagators }),
      trustIncomingTraceContext: this.trustIncomingTraceContext,
    });
  }

  /** The tracer the host instruments with. */
  get tracer(): Tracer {
    return this.tracerProvider.getTracer(this.instrumentationName);
  }
}
