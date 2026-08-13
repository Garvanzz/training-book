"""In-process rate limiting for credential endpoints.

ponytail: single-process, in-memory sliding window; fine for the personal
deployment this product targets.  A multi-worker deployment must replace
this with a shared store (Redis) behind the same check_and_record/clear
interface.
"""

from __future__ import annotations

import threading
from collections import deque
from time import monotonic

_lock = threading.Lock()
_buckets: dict[str, deque[float]] = {}

_MAX_ATTEMPTS = 10
_WINDOW_SECONDS = 15 * 60
# Bound memory under abuse: drop the oldest bucket when the map grows.
_MAX_BUCKETS = 10_000


def check_and_record(key: str) -> bool:
    """Record one attempt; False when the key is already over the limit."""

    now = monotonic()
    with _lock:
        bucket = _buckets.get(key)
        if bucket is None:
            if len(_buckets) >= _MAX_BUCKETS:
                oldest = min(_buckets, key=lambda name: _buckets[name][-1])
                del _buckets[oldest]
            bucket = deque()
            _buckets[key] = bucket
        while bucket and now - bucket[0] > _WINDOW_SECONDS:
            bucket.popleft()
        if len(bucket) >= _MAX_ATTEMPTS:
            return False
        bucket.append(now)
        return True


def clear(key: str) -> None:
    """Forget attempts for a key (e.g. after a successful login)."""

    with _lock:
        _buckets.pop(key, None)


def reset() -> None:
    """Drop all buckets; exposed for tests."""

    with _lock:
        _buckets.clear()
