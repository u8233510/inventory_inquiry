from __future__ import annotations

import os
from contextlib import contextmanager
from typing import Iterator

import pyodbc
from dotenv import load_dotenv

load_dotenv()


def _required(name: str) -> str:
    value = os.getenv(name, "").strip()
    if not value:
        raise RuntimeError(f"環境變數 {name} 尚未設定。")
    return value


def connection_string() -> str:
    driver = os.getenv("DB_DRIVER", "ODBC Driver 18 for SQL Server")
    server = _required("DB_SERVER")
    port = os.getenv("DB_PORT", "1433")
    database = _required("DB_DATABASE")
    username = _required("DB_USERNAME")
    password = _required("DB_PASSWORD")
    encrypt = os.getenv("DB_ENCRYPT", "yes")
    trust_cert = os.getenv("DB_TRUST_SERVER_CERTIFICATE", "yes")
    timeout = os.getenv("DB_CONNECTION_TIMEOUT", "10")

    return (
        f"DRIVER={{{driver}}};"
        f"SERVER={server},{port};"
        f"DATABASE={database};"
        f"UID={username};"
        f"PWD={password};"
        f"Encrypt={encrypt};"
        f"TrustServerCertificate={trust_cert};"
        f"Connection Timeout={timeout};"
        "MARS_Connection=yes;"
    )


@contextmanager
def get_connection() -> Iterator[pyodbc.Connection]:
    conn = pyodbc.connect(connection_string(), autocommit=True)
    try:
        query_timeout = int(os.getenv("DB_QUERY_TIMEOUT", "120"))
        conn.timeout = query_timeout
        yield conn
    finally:
        conn.close()
