"""Internal metric registry and public registrar for custom metrics.

MetricRegistry — stores all metrics, serializes to Prometheus text format.
MetricsRegistrar — public API that validates names before delegating.
"""

from __future__ import annotations

import re
import time
from typing import Any

from modular_api.core.metrics.metric import Counter, Gauge, Histogram

# ── Prometheus name validation ────────────────────────────────────────────

_VALID_NAME = re.compile(r"^[a-zA-Z_:][a-zA-Z0-9_:]*$")


def _assert_valid_name(name: str) -> None:
    if not name or not _VALID_NAME.match(name):
        raise ValueError(
            f'Invalid metric name "{name}": must match [a-zA-Z_:][a-zA-Z0-9_:]*'
        )


# ── MetricRegistry (internal) ────────────────────────────────────────────


class _MetricEntry:
    """An entry in the registry pairing metadata with a metric instance."""

    __slots__ = ("name", "help", "metric")

    def __init__(self, *, name: str, help: str, metric: Any) -> None:
        self.name = name
        self.help = help
        self.metric = metric

    @property
    def type_name(self) -> str:
        if isinstance(self.metric, Counter):
            return "counter"
        if isinstance(self.metric, Gauge):
            return "gauge"
        if isinstance(self.metric, Histogram):
            return "histogram"
        return "untyped"


class MetricRegistry:
    """Internal registry that holds all metrics and serializes them.

    On construction, registers ``process_start_time_seconds`` as a gauge
    set to the current epoch in seconds.
    """

    __slots__ = ("_metrics", "_names")

    def __init__(self) -> None:
        self._metrics: list[_MetricEntry] = []
        self._names: set[str] = set()

        # Auto-register process start time.
        start_gauge = self.create_gauge(
            name="process_start_time_seconds",
            help="Start time of the process since unix epoch in seconds.",
        )
        start_gauge.set(time.time())

    # ── Factory methods ──

    def create_counter(self, *, name: str, help: str) -> Counter:
        self._assert_unique(name)
        counter = Counter(name=name, help=help)
        self._metrics.append(_MetricEntry(name=name, help=help, metric=counter))
        return counter

    def create_gauge(self, *, name: str, help: str) -> Gauge:
        self._assert_unique(name)
        gauge = Gauge(name=name, help=help)
        self._metrics.append(_MetricEntry(name=name, help=help, metric=gauge))
        return gauge

    def create_histogram(
        self,
        *,
        name: str,
        help: str,
        buckets: list[float] | None = None,
    ) -> Histogram:
        self._assert_unique(name)
        hist = Histogram(name=name, help=help, buckets=buckets)
        self._metrics.append(_MetricEntry(name=name, help=help, metric=hist))
        return hist

    def _assert_unique(self, name: str) -> None:
        if name in self._names:
            raise ValueError(f'Metric "{name}" is already registered.')
        self._names.add(name)

    # ── Serialization ──

    def serialize(self) -> str:
        """Serializes all registered metrics to Prometheus text exposition format."""
        parts: list[str] = []

        for i, entry in enumerate(self._metrics):
            if i > 0:
                parts.append("")  # blank line between metric families

            parts.append(f"# HELP {entry.name} {entry.help}")
            parts.append(f"# TYPE {entry.name} {entry.type_name}")

            metric = entry.metric
            if isinstance(metric, Counter):
                self._serialize_counter(parts, metric)
            elif isinstance(metric, Gauge):
                self._serialize_gauge(parts, metric)
            elif isinstance(metric, Histogram):
                self._serialize_histogram(parts, metric)

        # Trailing newline to close the last line.
        parts.append("")
        return "\n".join(parts)

    @staticmethod
    def _serialize_counter(parts: list[str], counter: Counter) -> None:
        for sample in counter.collect():
            parts.append(
                f"{counter.name}{_format_labels(sample.labels)} {_format_value(sample.value)}"
            )

    @staticmethod
    def _serialize_gauge(parts: list[str], gauge: Gauge) -> None:
        samples = gauge.collect()
        if not samples:
            # Root gauge with no labeled children — emit root value.
            parts.append(f"{gauge.name} {_format_value(gauge.value)}")
        else:
            for sample in samples:
                parts.append(
                    f"{gauge.name}{_format_labels(sample.labels)} {_format_value(sample.value)}"
                )

    @staticmethod
    def _serialize_histogram(parts: list[str], histogram: Histogram) -> None:
        for sample in histogram.collect():
            parts.append(
                f"{histogram.name}{sample.suffix}{_format_labels(sample.labels)} "
                f"{_format_value(sample.value)}"
            )


def _format_labels(labels: dict[str, str]) -> str:
    if not labels:
        return ""
    pairs = ",".join(f'{k}="{v}"' for k, v in labels.items())
    return f"{{{pairs}}}"


def _format_value(v: float) -> str:
    """Integers → no decimal; otherwise standard float."""
    if v == int(v):
        return str(int(v))
    return str(v)


# ── MetricsRegistrar (public) ────────────────────────────────────────────


class MetricsRegistrar:
    """Public API for users to register custom metrics.

    Validates metric names and rejects reserved prefixes before
    delegating to the internal MetricRegistry.
    """

    __slots__ = ("_registry",)

    def __init__(self, registry: MetricRegistry) -> None:
        self._registry = registry

    def create_counter(self, *, name: str, help: str) -> Counter:
        self._validate(name)
        return self._registry.create_counter(name=name, help=help)

    def create_gauge(self, *, name: str, help: str) -> Gauge:
        self._validate(name)
        return self._registry.create_gauge(name=name, help=help)

    def create_histogram(
        self,
        *,
        name: str,
        help: str,
        buckets: list[float] | None = None,
    ) -> Histogram:
        self._validate(name)
        return self._registry.create_histogram(name=name, help=help, buckets=buckets)

    @staticmethod
    def _validate(name: str) -> None:
        _assert_valid_name(name)
        if name.startswith("__"):
            raise ValueError(
                f'Metric name "{name}" uses reserved prefix "__".'
            )
