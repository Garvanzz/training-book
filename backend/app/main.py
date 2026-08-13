from contextlib import asynccontextmanager

from fastapi import FastAPI
from fastapi.staticfiles import StaticFiles

from app.api.routes.auth import router as auth_router
from app.api.routes.library import router as library_router
from app.api.routes.plans import router as plans_router
from app.api.routes.progression import router as progression_router
from app.api.routes.sync import router as sync_router
from app.api.routes.workouts import router as workouts_router
from app.core.config import get_settings
from app.db.session import dispose_database


@asynccontextmanager
async def lifespan(_: FastAPI):
    yield
    await dispose_database()

app = FastAPI(
    title="Training Book API",
    version="0.1.0",
    description="Offline-first personal training data and exercise-library API.",
    lifespan=lifespan,
)
app.include_router(auth_router)
app.include_router(library_router)
app.include_router(plans_router)
app.include_router(progression_router)
app.include_router(sync_router)
app.include_router(workouts_router)

_media_root = get_settings().local_media_root
_media_root.mkdir(parents=True, exist_ok=True)
app.mount("/media", StaticFiles(directory=_media_root), name="local-media")


@app.get("/health", tags=["system"])
async def health() -> dict[str, str]:
    return {"status": "ok"}
