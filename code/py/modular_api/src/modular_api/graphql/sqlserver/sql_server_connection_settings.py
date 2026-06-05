"""Environment-backed SQL Server connection settings."""

from __future__ import annotations

import os
from dataclasses import dataclass
from typing import Mapping


@dataclass(frozen=True, slots=True)
class SqlServerConnectionSettings:
    host: str
    port: int
    database: str
    username: str
    password: str
    driver: str

    @classmethod
    def from_environment(
        cls,
        environment: Mapping[str, str] | None = None,
    ) -> "SqlServerConnectionSettings":
        env = environment or os.environ
        try:
            port = int(env.get("MODULAR_API_SQLSERVER_PORT", "14333"))
        except ValueError:
            port = 14333

        return cls(
            host=env.get("MODULAR_API_SQLSERVER_HOST", "127.0.0.1"),
            port=port,
            database=env.get("MODULAR_API_SQLSERVER_DATABASE", "modular_api_graphql_v1"),
            username=env.get("MODULAR_API_SQLSERVER_USERNAME", "sa"),
            password=env.get("MODULAR_API_SQLSERVER_PASSWORD", "ModularApi_dev_StrongPass1"),
            driver=env.get("MODULAR_API_SQLSERVER_DRIVER", "ODBC Driver 17 for SQL Server"),
        )

    def connection_string(self) -> str:
        return (
            f"DRIVER={{{self.driver}}};"
            f"SERVER={self.host},{self.port};"
            f"DATABASE={self.database};"
            f"UID={self.username};"
            f"PWD={self.password};"
            "Encrypt=no;"
            "TrustServerCertificate=yes;"
        )