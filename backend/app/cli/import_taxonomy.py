from __future__ import annotations

import asyncio
import json
from pathlib import Path
from uuid import NAMESPACE_URL, uuid5

from sqlalchemy import text

from app.db.session import system_transaction

_SEED_PATH = Path(__file__).resolve().parents[3] / "content" / "seed" / "taxonomy.zh-CN.json"


async def import_taxonomy() -> int:
    payload = json.loads(_SEED_PATH.read_text(encoding="utf-8"))
    terms = payload.get("terms")
    if not isinstance(terms, list) or not terms:
        raise ValueError("Taxonomy seed must contain a non-empty terms list.")

    async with system_transaction() as session:
        for term in terms:
            dimension = str(term["dimension"])
            code = str(term["code"])
            await session.execute(
                text(
                    """
                    INSERT INTO taxonomy_terms (id, dimension, code, name_zh, sort_order, is_active)
                    VALUES (:id, :dimension, :code, :name_zh, :sort_order, true)
                    ON CONFLICT (dimension, code) DO UPDATE SET
                        name_zh = EXCLUDED.name_zh,
                        sort_order = EXCLUDED.sort_order,
                        is_active = true,
                        updated_at = now()
                    """
                ),
                {
                    "id": uuid5(NAMESPACE_URL, f"training-book:taxonomy:{dimension}:{code}"),
                    "dimension": dimension,
                    "code": code,
                    "name_zh": str(term["name_zh"]),
                    "sort_order": int(term.get("sort_order", 0)),
                },
            )

    return len(terms)


def main() -> None:
    count = asyncio.run(import_taxonomy())
    print(f"Imported {count} taxonomy terms from {_SEED_PATH.name}.")


if __name__ == "__main__":
    main()
