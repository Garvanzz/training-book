from __future__ import annotations

import argparse
import asyncio
import getpass
import json
import os
from uuid import uuid4

from sqlalchemy import text

from app.core.security import hash_password
from app.db.session import system_transaction


async def create_owner(email: str, display_name: str, password: str) -> None:
    if len(password) < 12:
        raise ValueError("Password must be at least 12 characters long.")

    user_id = uuid4()
    async with system_transaction() as session:
        existing_owner = await session.scalar(
            text("SELECT EXISTS (SELECT 1 FROM users WHERE is_owner = true AND deleted_at IS NULL)")
        )
        if existing_owner:
            raise RuntimeError("An active owner already exists; this command only bootstraps the first owner.")

        await session.execute(
            text("SELECT set_config('app.user_id', :user_id, true)"),
            {"user_id": str(user_id)},
        )
        await session.execute(
            text(
                """
                INSERT INTO users (id, email, password_hash, is_active, is_owner)
                VALUES (:id, :email, :password_hash, true, true)
                """
            ),
            {"id": user_id, "email": email, "password_hash": hash_password(password)},
        )
        await session.execute(
            text("INSERT INTO profiles (user_id, display_name) VALUES (:user_id, :display_name)"),
            {"user_id": user_id, "display_name": display_name},
        )
        await session.execute(
            text(
                """
                INSERT INTO audit_logs (id, actor_user_id, action, entity_type, entity_id, after_json)
                VALUES (
                    :id,
                    :actor_user_id,
                    'bootstrap_owner',
                    'user',
                    :entity_id,
                    CAST(:after_json AS jsonb)
                )
                """
            ),
            {
                "id": uuid4(),
                "actor_user_id": user_id,
                "entity_id": user_id,
                "after_json": json.dumps({"email": email, "display_name": display_name}),
            },
        )


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Create the first Training Book owner account.")
    parser.add_argument("--email", required=True)
    parser.add_argument("--display-name", default="训练者")
    parser.add_argument(
        "--password-env",
        help="Read the initial password from this environment variable instead of prompting.",
    )
    return parser.parse_args()


def main() -> None:
    args = parse_args()
    email = args.email.strip().lower()
    if not email or "@" not in email:
        raise ValueError("A valid email address is required.")

    password = os.environ.get(args.password_env) if args.password_env else None
    if password is None:
        password = getpass.getpass("Initial owner password: ")

    asyncio.run(create_owner(email, args.display_name.strip(), password))
    print(f"Created the initial owner account for {email}.")


if __name__ == "__main__":
    main()
