"""Tests for the docs-ui handler (PRD-003).

Validates that /docs serves a bootloader HTML page that loads the
@macss/docs-ui widget from jsdelivr CDN.
"""

from starlette.routing import Route
from starlette.testclient import TestClient

from modular_api.openapi.swagger_docs import swagger_docs_handler


class TestSwaggerDocsHandler:
    """GET /docs returns an HTML page that loads @macss/docs-ui from CDN."""

    def _client(self, *, title: str = "My API") -> TestClient:
        endpoint = swagger_docs_handler(title=title)
        app = Route("/docs", endpoint=endpoint)
        return TestClient(app)

    # --- HTTP basics ---

    def test_returns_200(self) -> None:
        response = self._client().get("/docs")
        assert response.status_code == 200

    def test_content_type_is_html(self) -> None:
        response = self._client().get("/docs")
        assert "text/html" in response.headers["content-type"]

    # --- @macss/docs-ui CDN assets ---

    def test_docs_ui_cdn_reference(self) -> None:
        """Must load @macss/docs-ui from jsdelivr CDN."""
        response = self._client().get("/docs")
        assert "@macss/docs-ui" in response.text

    def test_docs_ui_bootloader(self) -> None:
        """Must call DocsUI.init to bootstrap the widget."""
        response = self._client().get("/docs")
        assert "DocsUI.init" in response.text

    # --- Configuration ---

    def test_references_openapi_json(self) -> None:
        """Bootloader must pass /openapi.json as the spec URL."""
        response = self._client().get("/docs")
        assert "/openapi.json" in response.text

    def test_no_scalar_regression(self) -> None:
        """PRD-003 regression guard: Scalar must not appear anywhere."""
        response = self._client().get("/docs")
        assert "scalar" not in response.text.lower()

    # --- Title interpolation ---

    def test_title_interpolated_in_html(self) -> None:
        response = self._client(title="Pet Store").get("/docs")
        assert "Pet Store" in response.text

    # --- HTML validity ---

    def test_html_is_valid_document(self) -> None:
        response = self._client().get("/docs")
        assert response.text.strip().startswith("<!DOCTYPE html>")
        assert "</html>" in response.text

    # --- Dark mode is now handled by @macss/docs-ui — tested in docs-ui/
