import logging

from fastapi import APIRouter, Depends
from sqlalchemy import text
from sqlalchemy.orm import Session

from app.database import get_db
from app.schemas import HealthCheck

logger = logging.getLogger(__name__)
router = APIRouter()

SERVICE_NAME = "{service}"  # Replace with docker-compose service name
SERVICE_VERSION = "1.0.0"


@router.get("/health", response_model=HealthCheck)
def health_check(db: Session = Depends(get_db)):
    """Standard health endpoint. See CONVENTIONS.md → Health Endpoint."""
    checks = {}

    try:
        db.execute(text("SELECT 1"))
        checks["database"] = "connected"
    except Exception:
        checks["database"] = "disconnected"

    all_ok = all(v in ("connected", "available") for v in checks.values())

    return HealthCheck(
        status="ok" if all_ok else "degraded",
        service=SERVICE_NAME,
        version=SERVICE_VERSION,
        checks=checks,
    )


# Add your resource endpoints below.
# See CONVENTIONS.md → API Contract for URL patterns and HTTP methods.
