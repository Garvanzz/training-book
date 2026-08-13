"""Unit tests for the in-process credential rate limiter."""

from __future__ import annotations

import pytest

from app.core import ratelimit


@pytest.fixture(autouse=True)
def clean_buckets() -> None:
    ratelimit.reset()


def test_blocks_after_max_attempts() -> None:
    for _ in range(ratelimit._MAX_ATTEMPTS):
        assert ratelimit.check_and_record("login:email:a@b.c") is True
    assert ratelimit.check_and_record("login:email:a@b.c") is False


def test_different_keys_do_not_share_budget() -> None:
    for _ in range(ratelimit._MAX_ATTEMPTS):
        ratelimit.check_and_record("login:email:a@b.c")
    assert ratelimit.check_and_record("login:ip:1.2.3.4") is True


def test_clear_forgets_attempts() -> None:
    for _ in range(ratelimit._MAX_ATTEMPTS):
        ratelimit.check_and_record("login:email:a@b.c")
    ratelimit.clear("login:email:a@b.c")
    assert ratelimit.check_and_record("login:email:a@b.c") is True


def test_window_expiry_frees_the_budget(monkeypatch) -> None:
    now = 1000.0

    class Clock:
        def __call__(self) -> float:
            return now

    monkeypatch.setattr(ratelimit, "monotonic", Clock())
    for _ in range(ratelimit._MAX_ATTEMPTS):
        ratelimit.check_and_record("login:email:a@b.c")
    assert ratelimit.check_and_record("login:email:a@b.c") is False

    now += ratelimit._WINDOW_SECONDS + 1
    assert ratelimit.check_and_record("login:email:a@b.c") is True
