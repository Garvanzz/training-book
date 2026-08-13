from functools import lru_cache
from pathlib import Path

from pydantic import Field
from pydantic_settings import BaseSettings, SettingsConfigDict


class Settings(BaseSettings):
    environment: str = "development"
    database_url: str
    migration_database_url: str | None = None
    jwt_issuer: str = "training-book"
    jwt_audience: str = "training-book-client"
    # HS256 is currently used, so an HMAC secret shorter than 256 bits is not
    # an acceptable production configuration.
    jwt_private_key: str = Field(min_length=32)
    access_token_minutes: int = 15
    refresh_token_days: int = 30
    offline_lease_days: int = 30
    # Self-service account creation.  Off by default: the first owner is
    # created by CLI, and additional accounts are created here when enabled.
    registration_enabled: bool = False
    # Personal/local mode stores reviewed exercise media beside the backend.
    # Production switches this boundary to object storage without changing the
    # exercise-library records or the client contract.
    local_media_root: Path = Path(__file__).resolve().parents[2] / "data" / "media"
    local_media_max_bytes: int = 1_073_741_824

    model_config = SettingsConfigDict(env_file=".env", case_sensitive=False)


@lru_cache
def get_settings() -> Settings:
    return Settings()
