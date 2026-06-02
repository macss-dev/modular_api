# example/example.py — Minimal runnable example.

# Mirrors ``example/example.dart`` (Dart) and ``example/example.ts`` (TypeScript).

# Run::

#     python -m example.example

# Then test::

#     curl -X POST http://localhost:8080/api/v1/greetings/hello-world \
#          -H "Content-Type: application/json" \
#          -d '{"name":"World"}'
#     curl http://localhost:8080/api/v1/time/current-time?tz=utc-5

# Docs::

#     http://localhost:8080/api/v1/docs

from __future__ import annotations

import sys

from modular_api import LogLevel, ModularApi

from .health.always_pass_health_check import AlwaysPassHealthCheck
from .modules.greetings.greetings_builder import build_greetings_module
from .modules.time.time_builder import build_time_module


# ── Server ────────────────────────────────────────────────────


def main() -> None:
    # First CLI arg overrides the default port (e.g. `python -m example.example 9090`).
    port = int(sys.argv[1]) if len(sys.argv) > 1 else 8080

    api = ModularApi(
        base_path="/api/v1",
        title="Modular API",
        version="1.0.0",
        # OpenAPI servers — shown in Swagger UI "Try it out" dropdown.
        # When omitted, defaults to http://localhost:{port}.
        # servers=[
        #     {"url": "https://miapi.example.com", "description": "Production"},
        #     {"url": "http://192.168.5.82:8080", "description": "LAN"},
        # ],
        metrics_enabled=True,
        log_level=LogLevel.debug,
    )

    api.add_health_check(AlwaysPassHealthCheck())

    if api.metrics:
        api.metrics.create_counter(
            name="greetings_total",
            help="Total number of greetings sent.",
        )

    api.module("greetings", build_greetings_module)
    api.module("time", build_time_module)

    api.serve(port=port)


if __name__ == "__main__":
    main()
