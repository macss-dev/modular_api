"""Tests for json_to_yaml — zero-dependency JSON-to-YAML converter."""

from __future__ import annotations

import pytest

from modular_api.openapi.openapi import json_to_yaml


class TestJsonToYamlEmptyStructures:
    """Empty maps and lists produce the YAML shorthand."""

    def test_empty_dict(self) -> None:
        assert json_to_yaml({}).strip() == "{}"

    def test_empty_list(self) -> None:
        assert json_to_yaml([]).strip() == "[]"


class TestJsonToYamlScalars:
    """Primitive values are rendered correctly."""

    def test_string_and_number(self) -> None:
        result = json_to_yaml({"key": "value", "num": 42})
        assert "key: value" in result
        assert "num: 42" in result

    def test_boolean_and_null(self) -> None:
        result = json_to_yaml({"flag": True, "off": False, "nothing": None})
        assert "flag: true" in result
        # 'off' is a YAML reserved word — the key is quoted
        assert "'off': false" in result
        assert "nothing: null" in result

    def test_float_value(self) -> None:
        result = json_to_yaml({"pi": 3.14})
        assert "pi: 3.14" in result


class TestJsonToYamlNestedObjects:
    """Nested dicts produce indented YAML."""

    def test_simple_nesting(self) -> None:
        result = json_to_yaml({"info": {"title": "Test", "version": "1.0.0"}})
        assert "info:" in result
        assert "  title: Test" in result
        assert "  version: 1.0.0" in result


class TestJsonToYamlLists:
    """Arrays serialize with '- ' prefix."""

    def test_list_of_strings(self) -> None:
        result = json_to_yaml({"tags": ["users", "admin"]})
        assert "tags:" in result
        assert "- users" in result
        assert "- admin" in result

    def test_list_of_objects(self) -> None:
        result = json_to_yaml({"servers": [{"url": "http://localhost:8000"}]})
        assert "servers:" in result
        assert "- url:" in result or "url:" in result


class TestJsonToYamlQuoting:
    """Strings that need YAML quoting get single-quoted."""

    def test_reserved_words_quoted(self) -> None:
        result = json_to_yaml({"reserved": "true"})
        assert "'true'" in result

    def test_special_characters_quoted(self) -> None:
        result = json_to_yaml({"special": "value: with colon"})
        assert "'value: with colon'" in result

    def test_empty_string_quoted(self) -> None:
        result = json_to_yaml({"empty": ""})
        assert "''" in result

    def test_numeric_string_quoted(self) -> None:
        result = json_to_yaml({"version": "3"})
        assert "'3'" in result

    def test_single_quote_in_value_escaped(self) -> None:
        result = json_to_yaml({"msg": "it's"})
        assert "it''s" in result

    def test_key_with_reserved_word(self) -> None:
        result = json_to_yaml({"yes": 1})
        assert "'yes': 1" in result


class TestJsonToYamlFullOpenApiStructure:
    """A realistic OpenAPI-like structure converts correctly."""

    def test_openapi_structure(self) -> None:
        spec = {
            "openapi": "3.0.0",
            "info": {"title": "Test API", "version": "1.0.0"},
            "paths": {
                "/api/test/ping": {
                    "post": {
                        "summary": "Ping endpoint",
                        "responses": {
                            "200": {"description": "OK"},
                        },
                    },
                },
            },
        }
        yaml = json_to_yaml(spec)
        assert "openapi: 3.0.0" in yaml
        assert "info:" in yaml
        assert "  title: Test API" in yaml
        assert "paths:" in yaml
        assert "/api/test/ping:" in yaml
