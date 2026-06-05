"""RED — Metrics middleware for Starlette: request counter, in-flight gauge, duration histogram."""

import pytest
from starlette.applications import Starlette
from starlette.requests import Request
from starlette.responses import PlainTextResponse, Response
from starlette.routing import Route
from starlette.testclient import TestClient

from modular_api.core.metrics.metric import Counter, Gauge, Histogram
from modular_api.core.metrics.metric_registry import MetricRegistry
from modular_api.core.metrics.metrics_middleware import metrics_handler, metrics_middleware


# ── Helpers ───────────────────────────────────────────────────────────────


def _make_metrics() -> tuple[MetricRegistry, Counter, Gauge, Histogram]:
    registry = MetricRegistry()
    total = registry.create_counter(name="http_requests_total", help="Total HTTP requests")
    in_flight = registry.create_gauge(name="http_requests_in_flight", help="Concurrent requests")
    duration = registry.create_histogram(
        name="http_request_duration_seconds", help="Request duration"
    )
    return registry, total, in_flight, duration


def _build_app(
    handler=None,
    *,
    excluded_routes: list[str] | None = None,
    registered_paths: list[str] | None = None,
) -> tuple[MetricRegistry, Counter, Gauge, Histogram, Starlette]:
    registry, total, in_flight, duration = _make_metrics()

    if handler is None:

        async def handler(request: Request) -> Response:
            return PlainTextResponse("ok")

    mw = metrics_middleware(
        requests_total=total,
        requests_in_flight=in_flight,
        request_duration=duration,
        excluded_routes=excluded_routes or [],
        registered_paths=registered_paths or [],
    )

    app = Starlette(routes=[
        Route("/api/greetings/hello", handler, methods=["GET", "POST"]),
        Route("/api/test", handler, methods=["GET", "POST"]),
        Route("/api/data", handler, methods=["GET"]),
        Route("/api/slow", handler, methods=["GET"]),
        Route("/health", handler, methods=["GET"]),
        Route("/metrics", handler, methods=["GET"]),
    ])
    app.add_middleware(mw)
    return registry, total, in_flight, duration, app


# ── metricsMiddleware ─────────────────────────────────────────────────────


class TestMetricsMiddleware:
    """Starlette middleware that instruments HTTP requests."""

    def test_increments_requests_total_with_correct_labels(self) -> None:
        _, total, _, _, app = _build_app(
            registered_paths=["/api/greetings/hello"],
        )
        client = TestClient(app)
        client.post("/api/greetings/hello")

        samples = total.collect()
        assert len(samples) == 1
        assert samples[0].labels["method"] == "POST"
        assert samples[0].labels["status_code"] == "200"
        assert samples[0].labels["route"] == "/api/greetings/hello"
        assert samples[0].value == 1.0

    def test_method_label_is_uppercase(self) -> None:
        _, total, _, _, app = _build_app()
        client = TestClient(app)
        client.get("/api/test")

        samples = total.collect()
        assert samples[0].labels["method"] == "GET"

    def test_status_code_label_is_string(self) -> None:
        async def not_found_handler(request: Request) -> Response:
            return Response(status_code=404)

        _, total, _, _, app = _build_app(handler=not_found_handler)
        client = TestClient(app)
        client.get("/api/test")

        samples = total.collect()
        assert samples[0].labels["status_code"] == "404"

    def test_unmatched_route_uses_unmatched_label(self) -> None:
        _, total, _, _, app = _build_app(
            registered_paths=["/api/greetings/hello"],
        )
        client = TestClient(app)
        client.get("/api/test")

        samples = total.collect()
        assert samples[0].labels["route"] == "UNMATCHED"

    def test_observes_request_duration(self) -> None:
        import asyncio

        async def slow_handler(request: Request) -> Response:
            await asyncio.sleep(0.05)
            return PlainTextResponse("done")

        _, _, _, duration, app = _build_app(handler=slow_handler)
        client = TestClient(app)
        client.get("/api/slow")

        samples = duration.collect()
        sum_sample = next(s for s in samples if s.suffix == "_sum")
        assert sum_sample.value > 0.04

    def test_manages_in_flight_gauge(self) -> None:
        _, _, in_flight, _, app = _build_app()
        client = TestClient(app)
        client.get("/api/test")

        # After completion, gauge should be back at 0.
        assert in_flight.value == 0.0

    def test_excludes_configured_routes(self) -> None:
        _, total, _, _, app = _build_app(
            excluded_routes=["/metrics", "/health"],
        )
        client = TestClient(app)
        client.get("/metrics")
        client.get("/health")

        assert total.collect() == []

    def test_does_not_exclude_non_matching_routes(self) -> None:
        _, total, _, _, app = _build_app(
            excluded_routes=["/metrics"],
        )
        client = TestClient(app)
        client.get("/api/data")

        assert len(total.collect()) == 1

    def test_accumulates_across_multiple_requests(self) -> None:
        _, total, _, _, app = _build_app(
            registered_paths=["/api/test"],
        )
        client = TestClient(app)
        client.get("/api/test")
        client.get("/api/test")
        client.post("/api/test")

        samples = total.collect()
        assert len(samples) == 2  # GET/200 and POST/200
        get_sample = next(s for s in samples if s.labels["method"] == "GET")
        assert get_sample.value == 2.0


# ── metricsHandler ────────────────────────────────────────────────────────


class TestMetricsHandler:
    """Starlette endpoint returning Prometheus text exposition format."""

    def test_returns_200_with_prometheus_content_type(self) -> None:
        registry = MetricRegistry()
        app = Starlette(routes=[
            Route("/metrics", metrics_handler(registry), methods=["GET"]),
        ])
        client = TestClient(app)
        resp = client.get("/metrics")
        assert resp.status_code == 200
        assert resp.headers["content-type"] == "text/plain; version=0.0.4; charset=utf-8"

    def test_body_contains_serialized_metrics(self) -> None:
        registry = MetricRegistry()
        registry.create_counter(name="test_total", help="A test")
        app = Starlette(routes=[
            Route("/metrics", metrics_handler(registry), methods=["GET"]),
        ])
        client = TestClient(app)
        resp = client.get("/metrics")
        assert "# HELP test_total A test" in resp.text
        assert "# TYPE test_total counter" in resp.text

    def test_body_contains_process_start_time(self) -> None:
        registry = MetricRegistry()
        app = Starlette(routes=[
            Route("/metrics", metrics_handler(registry), methods=["GET"]),
        ])
        client = TestClient(app)
        resp = client.get("/metrics")
        assert "process_start_time_seconds" in resp.text
