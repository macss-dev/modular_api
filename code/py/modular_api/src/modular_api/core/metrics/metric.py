"""Prometheus-compatible metric types: Counter, Gauge, Histogram.

Zero external dependencies — pure Python implementation mirroring
the Dart version's API surface for three-language parity.
"""

from __future__ import annotations

from dataclasses import dataclass


# ── MetricSample ──────────────────────────────────────────────────────────


@dataclass(frozen=True, slots=True)
class MetricSample:
    """A single data point collected from a metric."""

    name: str
    labels: dict[str, str]
    value: float
    suffix: str

    def __post_init__(self) -> None:
        # Coerce value to float regardless of the input type.
        object.__setattr__(self, "value", float(self.value))


# ── Shared helpers ────────────────────────────────────────────────────────


def _label_key(labels: dict[str, str]) -> str:
    """Canonical key for a label set so we can reuse children."""
    return ",".join(f"{k}={v}" for k, v in sorted(labels.items()))


# ── Counter ───────────────────────────────────────────────────────────────


class LabeledCounter:
    """Labeled counter child — holds a value for a specific label combination."""

    __slots__ = ("_labels", "_value")

    def __init__(self, labels: dict[str, str]) -> None:
        self._labels = dict(labels)
        self._value = 0.0

    @property
    def value(self) -> float:
        return self._value

    def inc(self, amount: float = 1) -> None:
        """Increments by *amount* (must be > 0)."""
        if amount <= 0:
            raise ValueError(f"Counter increment must be positive, got {amount}")
        self._value += amount


class Counter:
    """Monotonically increasing counter (Prometheus COUNTER type)."""

    __slots__ = ("name", "help", "_value", "_children")

    type: str = "counter"

    def __init__(self, *, name: str, help: str) -> None:
        self.name = name
        self.help = help
        self._value = 0.0
        self._children: dict[str, LabeledCounter] = {}

    @property
    def value(self) -> float:
        return self._value

    def inc(self, amount: float = 1) -> None:
        """Increments by *amount* (must be > 0)."""
        if amount <= 0:
            raise ValueError(f"Counter increment must be positive, got {amount}")
        self._value += amount

    def labels(self, label_values: dict[str, str]) -> LabeledCounter:
        """Returns (or creates) a child counter for the given label set."""
        key = _label_key(label_values)
        if key not in self._children:
            self._children[key] = LabeledCounter(label_values)
        return self._children[key]

    def collect(self) -> list[MetricSample]:
        """Collects samples from all labeled children."""
        return [
            MetricSample(
                name=self.name,
                labels=dict(child._labels),
                value=child.value,
                suffix="",
            )
            for child in self._children.values()
        ]


# ── Gauge ─────────────────────────────────────────────────────────────────


class LabeledGauge:
    """Labeled gauge child — holds a value for a specific label combination."""

    __slots__ = ("_labels", "_value")

    def __init__(self, labels: dict[str, str]) -> None:
        self._labels = dict(labels)
        self._value = 0.0

    @property
    def value(self) -> float:
        return self._value

    def set(self, v: float) -> None:
        self._value = float(v)

    def inc(self, amount: float = 1) -> None:
        self._value += amount

    def dec(self, amount: float = 1) -> None:
        self._value -= amount


class Gauge:
    """Value that can go up and down (Prometheus GAUGE type)."""

    __slots__ = ("name", "help", "_value", "_children")

    type: str = "gauge"

    def __init__(self, *, name: str, help: str) -> None:
        self.name = name
        self.help = help
        self._value = 0.0
        self._children: dict[str, LabeledGauge] = {}

    @property
    def value(self) -> float:
        return self._value

    def set(self, v: float) -> None:
        self._value = float(v)

    def inc(self, amount: float = 1) -> None:
        self._value += amount

    def dec(self, amount: float = 1) -> None:
        self._value -= amount

    def labels(self, label_values: dict[str, str]) -> LabeledGauge:
        """Returns (or creates) a child gauge for the given label set."""
        key = _label_key(label_values)
        if key not in self._children:
            self._children[key] = LabeledGauge(label_values)
        return self._children[key]

    def collect(self) -> list[MetricSample]:
        """Collects samples from all labeled children."""
        return [
            MetricSample(
                name=self.name,
                labels=dict(child._labels),
                value=child.value,
                suffix="",
            )
            for child in self._children.values()
        ]


# ── Histogram ─────────────────────────────────────────────────────────────

DEFAULT_BUCKETS: list[float] = [
    0.005, 0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1.0, 2.5, 5.0, 10.0,
]


class LabeledHistogram:
    """Labeled histogram child — holds buckets for a specific label combination."""

    __slots__ = ("_labels", "_boundaries", "_cumulative_counts", "_sum", "_count")

    def __init__(self, labels: dict[str, str], boundaries: list[float]) -> None:
        self._labels = dict(labels)
        self._boundaries = list(boundaries)
        self._cumulative_counts = [0] * (len(boundaries) + 1)
        self._sum = 0.0
        self._count = 0

    def observe(self, value: float) -> None:
        """Records an observation (must be >= 0)."""
        if value < 0:
            raise ValueError(f"Histogram observation must be non-negative, got {value}")
        self._count += 1
        self._sum += float(value)
        for i, boundary in enumerate(self._boundaries):
            if value <= boundary:
                self._cumulative_counts[i] += 1
        # +Inf bucket always incremented
        self._cumulative_counts[-1] += 1

    def collect(self, metric_name: str) -> list[MetricSample]:
        """Collects bucket, _count, and _sum samples."""
        samples: list[MetricSample] = []

        for i, boundary in enumerate(self._boundaries):
            samples.append(MetricSample(
                name=metric_name,
                labels={**self._labels, "le": _format_bucket(boundary)},
                value=self._cumulative_counts[i],
                suffix="_bucket",
            ))
        # +Inf bucket
        samples.append(MetricSample(
            name=metric_name,
            labels={**self._labels, "le": "+Inf"},
            value=self._cumulative_counts[-1],
            suffix="_bucket",
        ))
        # _count
        samples.append(MetricSample(
            name=metric_name,
            labels=dict(self._labels),
            value=self._count,
            suffix="_count",
        ))
        # _sum
        samples.append(MetricSample(
            name=metric_name,
            labels=dict(self._labels),
            value=self._sum,
            suffix="_sum",
        ))
        return samples


def _format_bucket(v: float) -> str:
    """Formats bucket boundary for Prometheus (integers get one decimal)."""
    if v == int(v):
        return f"{v:.1f}"
    return str(v)


def _validate_buckets(buckets: list[float]) -> None:
    if not buckets:
        raise ValueError("buckets must not be empty")
    for i in range(1, len(buckets)):
        if buckets[i] <= buckets[i - 1]:
            raise ValueError("buckets must be sorted in increasing order")


class Histogram:
    """Records observations in pre-defined buckets (Prometheus HISTOGRAM type)."""

    __slots__ = ("name", "help", "buckets", "_children")

    type: str = "histogram"

    def __init__(
        self,
        *,
        name: str,
        help: str,
        buckets: list[float] | None = None,
    ) -> None:
        self.name = name
        self.help = help
        self.buckets = list(buckets) if buckets is not None else list(DEFAULT_BUCKETS)
        _validate_buckets(self.buckets)
        self._children: dict[str, LabeledHistogram] = {}

    def observe(self, value: float) -> None:
        """Observe a value (must be >= 0). Uses an empty-label root child."""
        if value < 0:
            raise ValueError(f"Histogram observation must be non-negative, got {value}")
        self.labels({}).observe(value)

    def labels(self, label_values: dict[str, str]) -> LabeledHistogram:
        """Returns (or creates) a child histogram for the given label set."""
        key = _label_key(label_values)
        if key not in self._children:
            self._children[key] = LabeledHistogram(label_values, self.buckets)
        return self._children[key]

    def collect(self) -> list[MetricSample]:
        """Collects all samples across all label combinations."""
        samples: list[MetricSample] = []
        for child in self._children.values():
            samples.extend(child.collect(self.name))
        return samples
