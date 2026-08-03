import type { Context, TextMapGetter, TextMapPropagator, TextMapSetter } from '@opentelemetry/api';

/**
 * Combines several propagators into one, for publishing as the global propagator.
 *
 * `@opentelemetry/core` ships a `CompositePropagator`, and this exists because core may not
 * depend on it: that package is past the API boundary ADR-0005 A2 draws, and the Stage 1b
 * dependency guard names it explicitly. Dart needs no equivalent — its OpenTelemetry API
 * provides `OTelAPI.compositePropagator` directly, one of several places where the Dart API
 * is the richer of the three.
 *
 * Injection runs every propagator, so an outbound call can carry both `traceparent` and a
 * vendor header when the application asked for that. Extraction stops at the first
 * propagator that yields a valid span context, which is the precedence
 * {@link PropagationPolicy} defines — and why extraction here is a fallback rather than the
 * main path: the host resolves inbound context through the policy, not through this.
 */
export class CompositeTextMapPropagator implements TextMapPropagator<unknown> {
  constructor(private readonly propagators: readonly TextMapPropagator<unknown>[]) {}

  fields(): string[] {
    return [...new Set(this.propagators.flatMap((propagator) => propagator.fields()))];
  }

  inject(context: Context, carrier: unknown, setter: TextMapSetter<unknown>): void {
    for (const propagator of this.propagators) {
      try {
        propagator.inject(context, carrier, setter);
      } catch {
        // A third-party propagator is not our code. One misbehaving entry must not fail an
        // outbound request; the rest still get their headers on.
      }
    }
  }

  extract(context: Context, carrier: unknown, getter: TextMapGetter<unknown>): Context {
    for (const propagator of this.propagators) {
      try {
        const extracted = propagator.extract(context, carrier, getter);
        if (extracted !== context) return extracted;
      } catch {
        continue;
      }
    }
    return context;
  }
}
