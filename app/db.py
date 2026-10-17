import os
from contextlib import asynccontextmanager
from typing import AsyncGenerator

import psycopg
from psycopg.rows import dict_row
from psycopg_pool import AsyncConnectionPool

DATABASE_URL = os.getenv(
    "DATABASE_URL",
    "postgresql://parking_user:parking_pass@localhost:5432/parking_db"
)

pool: AsyncConnectionPool | None = None


async def init_pool() -> None:
    """Initialize the async connection pool on startup."""
    global pool
    pool = AsyncConnectionPool(
        DATABASE_URL,
        min_size=2,
        max_size=10,
        kwargs={"row_factory": dict_row},
        open=False,
    )
    await pool.open()


async def close_pool() -> None:
    """Close the pool on shutdown."""
    global pool
    if pool:
        await pool.close()
        pool = None


@asynccontextmanager
async def get_db() -> AsyncGenerator[psycopg.AsyncConnection, None]:
    """Async context manager that yields a connection from the pool."""
    if pool is None:
        raise RuntimeError("Database pool is not initialized")
    async with pool.connection() as conn:
        yield conn
