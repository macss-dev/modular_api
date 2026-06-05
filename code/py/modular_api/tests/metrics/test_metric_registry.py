"""RED — MetricRegistry (internal) and MetricsRegistrar (public)."""

import pytest

from modular_api.core.metrics.metric import Counter, Gauge, Histogram
from modular_api.core.metrics.metric_registry import MetricRegistry, MetricsRegistrar

# ── MetricRegistry ────────────────────────────────────────────────────────


class TestMetricRegistry:
    """Internal registry that holds all metrics and serializes them."""

    def test_registers_process_start_time_on_construction(self) -> None:
        registry = MetricRegistry()
        output = registry.serialize()
        assert "process_start_time_seconds" in output
        assert "# TYPE process_start_time_seconds gauge" in output

    def test_process_start_time_is_epoch_seconds(self) -> None:
        import time

        registry = MetricRegistry()
        output = registry.serialize()
        lines = output.split("\n")
        value_line = next(
            l
            for l in lines
            if l.startswith("process_start_time_seconds") and not l.startswith("#")
        )
        value = float(value_line.split(" ")[-1])
        assert abs(value - time.time()) < 5.0

    # ── Counter registration ──

    def test_create_counter_returns_counter(self) -> None:
        registry = MetricRegistry()
        counter = registry.create_counter(name="test_total", help="A test counter")
        assert isinstance(counter, Counter)
        assert counter.name == "test_total"

    def test_create_counter_rejects_duplicate(self) -> None:
        registry = MetricRegistry()
        registry.create_counter(name="dup", help="h")
        with pytest.raises(ValueError):
            registry.create_counter(name="dup", help="h")

    # ── Gauge registration ──

    def test_create_gauge_returns_gauge(self) -> None:
        registry = MetricRegistry()
        gauge = registry.create_gauge(name="test_gauge", help="A gauge")
        assert isinstance(gauge, Gauge)
        assert gauge.name == "test_gauge"

    def test_create_gauge_rejects_duplicate(self) -> None:
        registry = MetricRegistry()
        registry.create_gauge(name="dup", help="h")
        with pytest.raises(ValueError):
            registry.create_gauge(name="dup", help="h")

    # ── Histogram registration ──

    def test_create_histogram_returns_histogram(self) -> None:
        registry = MetricRegistry()
        hist = registry.create_histogram(name="test_hist", help="A histogram")
        assert isinstance(hist, Histogram)
        assert hist.name == "test_hist"

    def test_create_histogram_with_custom_buckets(self) -> None:
        registry = MetricRegistry()
        hist = registry.create_histogram(
            name="custom_hist", help="h", buckets=[0.1, 1.0, 10.0]
        )
        assert hist.buckets == [0.1, 1.0, 10.0]

    def test_create_histogram_rejects_duplicate(self) -> None:
        registry = MetricRegistry()
        registry.create_histogram(name="dup", help="h")
        with pytest.raises(ValueError):
            registry.create_histogram(name="dup", help="h")

    # ── Cross-type duplicate ──

    def test_rejects_duplicate_across_types(self) -> None:
        registry = MetricRegistry()
        registry.create_counter(name="shared", help="h")
        with pytest.raises(ValueError):
            registry.create_gauge(name="shared", help="h")


class TestMetricRegistrySerialization:
    """Prometheus text exposition format output."""

    def test_empty_registry_has_only_process_start_time(self) -> None:
        registry = MetricRegistry()
        output = registry.serialize()
        help_lines = [l for l in output.split("\n") if l.startswith("# HELP")]
        assert len(help_lines) == 1

    def test_serializes_counter_with_help_type_value(self) -> None:
        registry = MetricRegistry()
        counter = registry.create_counter(
            name="http_requests_total", help="Total HTTP requests"
        )
        counter.labels({"method": "GET", "status_code": "200"}).inc(42)

        output = registry.serialize()
        assert "# HELP http_requests_total Total HTTP requests" in output
        assert "# TYPE http_requests_total counter" in output
        assert 'http_requests_total{method="GET",status_code="200"} 42' in output

    def test_serializes_gauge(self) -> None:
        registry = MetricRegistry()
        gauge = registry.create_gauge(name="temperature", help="Current temperature")
        gauge.labels({"location": "office"}).set(22.5)

        output = registry.serialize()
        assert "# TYPE temperature gauge" in output
        assert 'temperature{location="office"} 22.5' in output

    def test_serializes_histogram_with_buckets_count_sum(self) -> None:
        registry = MetricRegistry()
        hist = registry.create_histogram(
            name="request_duration", help="Duration", buckets=[0.1, 0.5, 1.0]
        )
        hist.labels({"method": "GET"}).observe(0.3)

        output = registry.serialize()
        assert "# TYPE request_duration histogram" in output
        assert 'request_duration_bucket{method="GET",le="0.1"} 0' in output
        assert 'request_duration_bucket{method="GET",le="0.5"} 1' in output
        assert 'request_duration_bucket{method="GET",le="1.0"} 1' in output
        assert 'request_duration_bucket{method="GET",le="+Inf"} 1' in output
        assert 'request_duration_count{method="GET"} 1' in output
        assert 'request_duration_sum{method="GET"} 0.3' in output

    def test_output_ends_with_newline(self) -> None:
        registry = MetricRegistry()
        assert registry.serialize().endswith("\n")

    def test_separate_metrics_with_blank_line(self) -> None:
        registry = MetricRegistry()
        registry.create_counter(name="a", help="ha")
        registry.create_gauge(name="b", help="hb")
        output = registry.serialize()
        assert "\n\n" in output


# ── MetricsRegistrar ──────────────────────────────────────────────────────


class TestMetricsRegistrar:
    """Public API validates names and delegates to MetricRegistry."""

    def _make(self) -> tuple[MetricRegistry, MetricsRegistrar]:
        registry = MetricRegistry()
        return registry, MetricsRegistrar(registry)

    def test_create_counter_validates_name(self) -> None:
        _, registrar = self._make()
        with pytest.raises(ValueError):
            registrar.create_counter(name="", help="h")
        with pytest.raises(ValueError):
            registrar.create_counter(name="123bad", help="h")
        with pytest.raises(ValueError):
            registrar.create_counter(name="has space", help="h")

    def test_create_counter_accepts_valid_name(self) -> None:
        _, registrar = self._make()
        counter = registrar.create_counter(name="my_app_requests_total", help="My counter")
        assert isinstance(counter, Counter)

    def test_create_gauge_validates_name(self) -> None:
        _, registrar = self._make()
        with pytest.raises(ValueError):
            registrar.create_gauge(name="", help="h")

    def test_create_gauge_accepts_valid_name(self) -> None:
        _, registrar = self._make()
        gauge = registrar.create_gauge(name="my_gauge", help="A gauge")
        assert isinstance(gauge, Gauge)

    def test_create_histogram_validates_name(self) -> None:
        _, registrar = self._make()
        with pytest.raises(ValueError):
            registrar.create_histogram(name="!invalid", help="h")

    def test_create_histogram_accepts_valid_name_and_buckets(self) -> None:
        _, registrar = self._make()
        hist = registrar.create_histogram(name="my_hist", help="A hist", buckets=[0.5, 1.0])
        assert isinstance(hist, Histogram)

    def test_rejects_reserved_prefix(self) -> None:
        _, registrar = self._make()
        with pytest.raises(ValueError):
            registrar.create_counter(name="__internal", help="h")

    def test_custom_metrics_appear_in_serialization(self) -> None:
        registry, registrar = self._make()
        registrar.create_counter(name="custom_total", help="Custom counter")
        output = registry.serialize()
        assert "# HELP custom_total Custom counter" in output
