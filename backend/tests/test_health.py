import asyncio

from app.main import health


def test_health() -> None:
    response = asyncio.run(health())

    assert response == {"status": "ok"}
