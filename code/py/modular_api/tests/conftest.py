"""Shared pytest configuration for the Python test suite.

On Windows, asyncio defaults to ``ProactorEventLoop`` (IOCP based). Starlette's
``TestClient`` spins up a throwaway blocking portal — and therefore a fresh
event loop — for every request issued outside a ``with`` block. The Proactor
loop's IOCP handles and internal socketpair are torn down by finalizers during
``gc.collect()``; when the full suite creates and abandons hundreds of these
loops, that finalization occasionally races and segfaults the interpreter
(``Windows fatal exception: access violation`` raised from pytest's
``unraisableexception`` plugin).

The ``SelectorEventLoop`` does not use IOCP and finalizes cleanly, so forcing it
for the test session makes the Python suite as robust as the Dart and
TypeScript suites without touching any production code.
"""

from __future__ import annotations

import asyncio
import sys

if sys.platform.startswith("win"):
    asyncio.set_event_loop_policy(asyncio.WindowsSelectorEventLoopPolicy())
