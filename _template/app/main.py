import logging
from contextlib import asynccontextmanager

from fastapi import FastAPI

from app.database import Base, engine
from app.routes import router

# Logging format per CONVENTIONS.md → Logging
logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(name)s: %(message)s",
    datefmt="%Y-%m-%dT%H:%M:%SZ",
)
logger = logging.getLogger(__name__)


@asynccontextmanager
async def lifespan(app: FastAPI):
    logger.info("Creating database tables...")
    Base.metadata.create_all(bind=engine)
    logger.info("Database tables ready.")

    # Add service-specific startup here (model loading, cache warming, etc.)

    yield

    logger.info("Shutting down.")


app = FastAPI(
    title="{Service Name}",
    description="{Brief description}",
    version="1.0.0",
    lifespan=lifespan,
)

app.include_router(router)
