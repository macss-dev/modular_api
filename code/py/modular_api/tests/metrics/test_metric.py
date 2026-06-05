"""RED — Prometheus metric types: Counter, Gauge, Histogram, MetricSample."""

import pytest

from modular_api.core.metrics.metric import (
    Counter,
    Gauge,
    Histogram,
    MetricSample,
)

# ── MetricSample ──────────────────────────────────────────────────────────


class TestMetricSample:
    """A single data point collected from a metric."""

    def test_holds_name_labels_value_suffix(self) -> None:
        sample = MetricSample(
            name="http_requests_total",
            labels={"method": "GET", "status_code": "200"},
            value=42,
            suffix="",
        )
        assert sample.name == "http_requests_total"
        assert sample.labels == {"method": "GET", "status_code": "200"}
        assert sample.value == 42.0
        assert sample.suffix == ""

    def test_value_is_coerced_to_float(self) -> None:
        sample = MetricSample(name="m", labels={}, value=7, suffix="")
        assert isinstance(sample.value, float)


# ── Counter ───────────────────────────────────────────────────────────────


class TestCounter:
    """Monotonically increasing counter (Prometheus COUNTER type)."""

    def test_starts_at_zero(self) -> None:
        counter = Counter(name="http_requests_total", help="Total requests")
        assert counter.value == 0.0

    def test_inc_increments_by_one(self) -> None:
        counter = Counter(name="c", help="h")
        counter.inc()
        assert counter.value == 1.0

    def test_inc_with_custom_amount(self) -> None:
        counter = Counter(name="c", help="h")
        counter.inc(5)
        assert counter.value == 5.0

    def test_inc_accumulates(self) -> None:
        counter = Counter(name="c", help="h")
        counter.inc(3)
        counter.inc(2)
        assert counter.value == 5.0

    def test_inc_raises_on_negative(self) -> None:
        counter = Counter(name="c", help="h")
        with pytest.raises(ValueError):
            counter.inc(-1)

    def test_inc_raises_on_zero(self) -> None:
        counter = Counter(name="c", help="h")
        with pytest.raises(ValueError):
            counter.inc(0)

    def test_labels_returns_child(self) -> None:
        counter = Counter(name="http_requests_total", help="h")
        child = counter.labels({"method": "GET", "status_code": "200"})
        child.inc()
        assert child.value == 1.0

    def test_labels_returns_same_child_for_same_label_set(self) -> None:
        counter = Counter(name="c", help="h")
        a = counter.labels({"method": "GET"})
        b = counter.labels({"method": "GET"})
        a.inc()
        assert b.value == 1.0

    def test_labels_returns_different_children_for_different_labels(self) -> None:
        counter = Counter(name="c", help="h")
        get = counter.labels({"method": "GET"})
        post = counter.labels({"method": "POST"})
        get.inc(3)
        post.inc(1)
        assert get.value == 3.0
        assert post.value == 1.0

    def test_exposes_name_and_help(self) -> None:
        counter = Counter(name="my_counter", help="A counter")
        assert counter.name == "my_counter"
        assert counter.help == "A counter"

    def test_type_is_counter(self) -> None:
        counter = Counter(name="c", help="h")
        assert counter.type == "counter"

    def test_collect_returns_all_label_combinations(self) -> None:
        counter = Counter(name="req", help="h")
        counter.labels({"method": "GET"}).inc(10)
        counter.labels({"method": "POST"}).inc(5)
        samples = counter.collect()
        assert len(samples) == 2


# ── Gauge ─────────────────────────────────────────────────────────────────


class TestGauge:
    """Value that can go up and down (Prometheus GAUGE type)."""

    def test_starts_at_zero(self) -> None:
        gauge = Gauge(name="in_flight", help="Concurrent requests")
        assert gauge.value == 0.0

    def test_set_value(self) -> None:
        gauge = Gauge(name="g", help="h")
        gauge.set(42)
        assert gauge.value == 42.0

    def test_set_overwrites_previous_value(self) -> None:
        gauge = Gauge(name="g", help="h")
        gauge.set(10)
        gauge.set(20)
        assert gauge.value == 20.0

    def test_inc_increments_by_one(self) -> None:
        gauge = Gauge(name="g", help="h")
        gauge.inc()
        assert gauge.value == 1.0

    def test_inc_with_custom_amount(self) -> None:
        gauge = Gauge(name="g", help="h")
        gauge.inc(5)
        assert gauge.value == 5.0

    def test_dec_decrements_by_one(self) -> None:
        gauge = Gauge(name="g", help="h")
        gauge.set(5)
        gauge.dec()
        assert gauge.value == 4.0

    def test_dec_with_custom_amount(self) -> None:
        gauge = Gauge(name="g", help="h")
        gauge.set(10)
        gauge.dec(3)
        assert gauge.value == 7.0

    def test_can_go_negative(self) -> None:
        gauge = Gauge(name="g", help="h")
        gauge.dec(5)
        assert gauge.value == -5.0

    def test_labels_returns_child(self) -> None:
        gauge = Gauge(name="g", help="h")
        child = gauge.labels({"route": "/api/test"})
        child.set(99)
        assert child.value == 99.0

    def test_labels_returns_same_child_for_same_label_set(self) -> None:
        gauge = Gauge(name="g", help="h")
        a = gauge.labels({"k": "v"})
        b = gauge.labels({"k": "v"})
        a.set(42)
        assert b.value == 42.0

    def test_type_is_gauge(self) -> None:
        gauge = Gauge(name="g", help="h")
        assert gauge.type == "gauge"

    def test_collect_returns_all_label_combinations(self) -> None:
        gauge = Gauge(name="g", help="h")
        gauge.labels({"a": "1"}).set(10)
        gauge.labels({"a": "2"}).set(20)
        samples = gauge.collect()
        assert len(samples) == 2


# ── Histogram ─────────────────────────────────────────────────────────────


class TestHistogram:
    """Records observations in pre-defined buckets (Prometheus HISTOGRAM type)."""

    DEFAULT_BUCKETS = [0.005, 0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1.0, 2.5, 5.0, 10.0]

    def test_uses_default_buckets_when_none_provided(self) -> None:
        hist = Histogram(name="http_request_duration_seconds", help="Duration")
        assert hist.buckets == self.DEFAULT_BUCKETS

    def test_accepts_custom_buckets(self) -> None:
        hist = Histogram(name="h", help="h", buckets=[0.1, 0.5, 1.0])
        assert hist.buckets == [0.1, 0.5, 1.0]

    def test_raises_on_empty_buckets(self) -> None:
        with pytest.raises(ValueError):
            Histogram(name="h", help="h", buckets=[])

    def test_raises_on_unsorted_buckets(self) -> None:
        with pytest.raises(ValueError):
            Histogram(name="h", help="h", buckets=[1.0, 0.5])

    def test_observe_records_value_in_correct_buckets(self) -> None:
        hist = Histogram(name="h", help="h", buckets=[0.1, 0.5, 1.0])
        hist.observe(0.3)

        samples = hist.collect()
        bucket_samples = [s for s in samples if s.suffix == "_bucket"]
        assert len(bucket_samples) == 4  # 3 boundaries + Inf

        by_le = {s.labels["le"]: s.value for s in bucket_samples}
        assert by_le["0.1"] == 0.0  # 0.3 > 0.1
        assert by_le["0.5"] == 1.0  # 0.3 <= 0.5
        assert by_le["1.0"] == 1.0  # 0.3 <= 1.0
        assert by_le["+Inf"] == 1.0

    def test_observe_accumulates_count_and_sum(self) -> None:
        hist = Histogram(name="h", help="h", buckets=[1.0])
        hist.observe(0.5)
        hist.observe(0.8)

        samples = hist.collect()
        count = next(s for s in samples if s.suffix == "_count").value
        total = next(s for s in samples if s.suffix == "_sum").value
        assert count == 2.0
        assert total == pytest.approx(1.3)

    def test_observe_raises_on_negative(self) -> None:
        hist = Histogram(name="h", help="h")
        with pytest.raises(ValueError):
            hist.observe(-1)

    def test_labels_returns_child(self) -> None:
        hist = Histogram(name="h", help="h", buckets=[1.0])
        child = hist.labels({"method": "GET"})
        child.observe(0.5)

        samples = hist.collect()
        count_samples = [s for s in samples if s.suffix == "_count"]
        assert len(count_samples) == 1
        assert count_samples[0].labels["method"] == "GET"

    def test_labels_returns_same_child_for_same_label_set(self) -> None:
        hist = Histogram(name="h", help="h", buckets=[1.0])
        a = hist.labels({"m": "GET"})
        b = hist.labels({"m": "GET"})
        a.observe(0.5)
        b.observe(1.0)

        samples = hist.collect()
        count = next(s for s in samples if s.suffix == "_count").value
        assert count == 2.0

    def test_type_is_histogram(self) -> None:
        hist = Histogram(name="h", help="h")
        assert hist.type == "histogram"

    def test_collect_with_no_observations_returns_empty(self) -> None:
        hist = Histogram(name="h", help="h")
        assert hist.collect() == []
