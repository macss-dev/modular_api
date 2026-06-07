"""Stage 0 red baseline tests for the future plugin host."""

from __future__ import annotations

from starlette.testclient import TestClient

from modular_api import ModularApi, Plugin, PluginHost, PluginManifest


class ProbePlugin(Plugin):
    manifest = PluginManifest(
        id="acme.echo",
        display_name="Echo Probe",
        version="0.1.0",
        host_api_version=">=0.1.0 <0.2.0",
    )

    def setup(self, host: PluginHost) -> None:
        host.register_route(
            {
                "id": "probe-route",
                "method": "GET",
                "path": "/plugin-probe",
                "visibility": "custom",
                "handler": lambda _context: {"status": 200, "body": {"ok": True}},
            }
        )


def test_exposes_plugin_registration_and_public_plugin_types() -> None:
    api = ModularApi(base_path="/api")
    plugin = ProbePlugin()

    assert api.plugin(plugin) is api
    assert plugin.manifest.id == "acme.echo"


def test_mounts_plugin_routes_only_under_the_shared_base_path() -> None:
    api = ModularApi(base_path="/api").plugin(ProbePlugin())
    client = TestClient(api.build())

    assert client.get("/api/plugin-probe").status_code == 200
    assert client.get("/plugin-probe").status_code == 404