from __future__ import annotations

import pytest
from starlette.testclient import TestClient

from modular_api import (
    HOST_API_VERSION,
    HostMetadata,
    ModularApi,
    Plugin,
    PluginHost,
    PluginHostError,
    PluginManifest,
    PluginRequirement,
    PluginValidationResult,
)


class RecordingPlugin(Plugin):
    def __init__(self, plugin_id: str, events: list[str] | None = None) -> None:
        self.manifest = PluginManifest(
            id=plugin_id,
            display_name="Recording Plugin",
            version="0.1.0",
            host_api_version=">=0.1.0 <0.2.0",
        )
        self.setup_calls = 0
        self.observed_metadata: HostMetadata | None = None
        self.events = events

    def setup(self, host: PluginHost) -> None:
        self.setup_calls += 1
        self.observed_metadata = host.metadata()
        if self.events is not None:
            self.events.append(f"setup:{self.manifest.id}")


def test_setup_does_not_run_during_registration() -> None:
    plugin = RecordingPlugin("acme.lifecycle")
    api = ModularApi(base_path="/api", title="Lifecycle API", version="1.2.3")

    api.plugin(plugin)

    assert plugin.setup_calls == 0
    assert plugin.observed_metadata is None


def test_setup_runs_during_build_and_exposes_metadata() -> None:
    plugin = RecordingPlugin("acme.lifecycle")
    api = ModularApi(base_path="/api", title="Lifecycle API", version="1.2.3").plugin(plugin)

    api.build()

    assert plugin.setup_calls == 1
    assert plugin.observed_metadata == HostMetadata(
        base_path="/api",
        title="Lifecycle API",
        version="1.2.3",
        host_api_version=HOST_API_VERSION,
    )


def test_duplicate_plugin_ids_fail_startup() -> None:
    api = ModularApi(base_path="/api")
    api.plugin(RecordingPlugin("acme.duplicate"))
    api.plugin(RecordingPlugin("acme.duplicate"))

    with pytest.raises(PluginHostError) as excinfo:
        api.build()

    assert excinfo.value.code == "PLUGIN_ID_CONFLICT"


def test_dependency_order_controls_setup_order_and_registration_breaks_ties() -> None:
    events: list[str] = []
    api = ModularApi(base_path="/api")
    api.plugin(DependentPlugin("acme.child-b", "acme.root", events))
    api.plugin(DependentPlugin("acme.child-a", "acme.root", events))
    api.plugin(RecordingPlugin("acme.root", events))

    api.build()

    assert events == ["setup:acme.root", "setup:acme.child-b", "setup:acme.child-a"]


def test_plugin_validation_runs_after_setup_and_aborts_startup() -> None:
    plugin = InvalidatingPlugin("acme.invalid")
    api = ModularApi(base_path="/api").plugin(plugin)

    with pytest.raises(PluginHostError) as excinfo:
        api.build()

    assert excinfo.value.code == "PLUGIN_VALIDATION_FAILED"
    assert plugin.setup_calls == 1
    assert plugin.validate_calls == 1


def test_shutdown_runs_in_reverse_setup_order() -> None:
    events: list[str] = []
    api = ModularApi(base_path="/api")
    api.plugin(ShutdownPlugin("acme.child", events, dependency_id="acme.root"))
    api.plugin(ShutdownPlugin("acme.root", events))

    with TestClient(api.build()):
        pass

    assert events == [
        "setup:acme.root",
        "setup:acme.child",
        "shutdown:acme.child",
        "shutdown:acme.root",
    ]


def test_shutdown_runs_for_already_setup_plugins_when_validation_aborts_startup() -> None:
    events: list[str] = []
    api = ModularApi(base_path="/api")
    api.plugin(ShutdownPlugin("acme.root", events))
    api.plugin(FailingShutdownPlugin("acme.invalid", events))

    with pytest.raises(PluginHostError) as excinfo:
        api.build()

    assert excinfo.value.code == "PLUGIN_VALIDATION_FAILED"
    assert events == [
        "setup:acme.root",
        "setup:acme.invalid",
        "shutdown:acme.invalid",
        "shutdown:acme.root",
    ]


def test_late_host_registration_is_rejected_after_startup_freeze() -> None:
    plugin = LateRegistrationPlugin("acme.late")
    api = ModularApi(base_path="/api").plugin(plugin)

    api.build()

    with pytest.raises(PluginHostError) as excinfo:
        plugin.register_late_route()

    assert excinfo.value.code == "PLUGIN_VALIDATION_FAILED"


class DependentPlugin(RecordingPlugin):
    def __init__(self, plugin_id: str, dependency_id: str, events: list[str]) -> None:
        super().__init__(plugin_id, events)
        self.manifest = PluginManifest(
            id=plugin_id,
            display_name="Recording Plugin",
            version="0.1.0",
            host_api_version=">=0.1.0 <0.2.0",
            requires=[PluginRequirement(type="plugin", id=dependency_id)],
        )


class InvalidatingPlugin(RecordingPlugin):
    def __init__(self, plugin_id: str) -> None:
        super().__init__(plugin_id)
        self.validate_calls = 0

    def validate(self, host: PluginHost) -> list[PluginValidationResult]:
        self.validate_calls += 1
        return [
            PluginValidationResult(
                code="PLUGIN_VALIDATION_FAILED",
                message="invalid plugin",
                plugin_id=self.manifest.id,
            )
        ]


class ShutdownPlugin(RecordingPlugin):
    def __init__(self, plugin_id: str, events: list[str], dependency_id: str | None = None) -> None:
        super().__init__(plugin_id, events)
        self.manifest = PluginManifest(
            id=plugin_id,
            display_name="Recording Plugin",
            version="0.1.0",
            host_api_version=">=0.1.0 <0.2.0",
            requires=[] if dependency_id is None else [PluginRequirement(type="plugin", id=dependency_id)],
        )

    async def shutdown(self) -> None:
        assert self.events is not None
        self.events.append(f"shutdown:{self.manifest.id}")


class FailingShutdownPlugin(ShutdownPlugin):
    def validate(self, host: PluginHost) -> list[PluginValidationResult]:
        return [
            PluginValidationResult(
                code="PLUGIN_VALIDATION_FAILED",
                message="invalid plugin",
                plugin_id=self.manifest.id,
            )
        ]


class LateRegistrationPlugin(RecordingPlugin):
    def __init__(self, plugin_id: str) -> None:
        super().__init__(plugin_id)
        self._host: PluginHost | None = None

    def setup(self, host: PluginHost) -> None:
        super().setup(host)
        self._host = host

    def register_late_route(self) -> None:
        assert self._host is not None
        self._host.register_route(
            {
                "id": "late-route",
                "method": "GET",
                "path": "/late",
                "visibility": "custom",
                "handler": lambda _context: {"status": 200, "body": {"ok": True}},
            }
        )