/// Shelf middleware and handler for Prometheus metrics collection.
library;

import 'package:shelf/shelf.dart';
import 'metric.dart';
import 'metric_registry.dart';

/// Creates a Shelf [Middleware] that instruments HTTP requests.
///
/// Records:
/// - [requestsTotal] — counter with labels: method, route, status_code
/// - [requestsInFlight] — gauge (inc on entry, dec on exit)
/// - [requestDuration] — histogram with labels: method, route, status_code
///
/// Requests whose path matches any entry in [excludedRoutes] are passed
/// through without recording metrics.
///
/// [registeredPaths] is used for route normalization: if the request path
/// matches a registered route, that path is used as the `route` label;
/// otherwise `"UNMATCHED"` is used.
Middleware metricsMiddleware({
  required Counter requestsTotal,
  required Gauge requestsInFlight,
  required Histogram requestDuration,
  List<String> excludedRoutes = const [],
  List<String> registeredPaths = const [],
}) {
  final excludedSet = Set<String>.from(excludedRoutes);
  final registeredSet = Set<String>.from(registeredPaths);

  return (Handler innerHandler) {
    return (Request request) async {
      final path = request.requestedUri.path;

      // Skip excluded routes.
      if (excludedSet.contains(path)) {
        return innerHandler(request);
      }

      final method = request.method.toUpperCase();
      final route = registeredSet.contains(path) ? path : 'UNMATCHED';

      requestsInFlight.inc();
      final stopwatch = Stopwatch()..start();

      try {
        final response = await innerHandler(request);
        stopwatch.stop();

        final statusCode = response.statusCode.toString();
        final durationSecs = stopwatch.elapsedMicroseconds / 1000000;

        final labels = {
          'method': method,
          'route': route,
          'status_code': statusCode,
        };

        requestsTotal.labels(labels).inc();
        requestDuration.labels(labels).observe(durationSecs);

        return response;
      } catch (e) {
        stopwatch.stop();

        final durationSecs = stopwatch.elapsedMicroseconds / 1000000;
        final labels = {
          'method': method,
          'route': route,
          'status_code': '500',
        };

        requestsTotal.labels(labels).inc();
        requestDuration.labels(labels).observe(durationSecs);

        rethrow;
      } finally {
        requestsInFlight.dec();
      }
    };
  };
}

/// Creates a Shelf [Handler] that returns the serialized Prometheus metrics.
///
/// Always returns HTTP 200 with content type
/// `text/plain; version=0.0.4; charset=utf-8`.
Handler metricsHandler(MetricRegistry registry) {
  return (Request request) {
    final body = registry.serialize();
    return Response.ok(
      body,
      headers: {
        'content-type': 'text/plain; version=0.0.4; charset=utf-8',
      },
    );
  };
}
