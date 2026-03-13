import uuid
from datetime import datetime

from pydantic import BaseModel


# Response schemas — see CONVENTIONS.md → API Contract for standard shapes.


class HealthCheck(BaseModel):
    """Standard health response. See CONVENTIONS.md → Health Endpoint."""

    status: str
    service: str
    version: str
    checks: dict[str, str]


class ErrorDetail(BaseModel):
    """Standard error response. See CONVENTIONS.md → Error Responses."""

    code: str
    message: str
    details: dict | None = None


class ErrorResponse(BaseModel):
    error: ErrorDetail


# Resource schemas — replace with your actual resource.


class ExampleResourceResponse(BaseModel):
    id: uuid.UUID
    name: str
    status: str
    created_at: datetime
    updated_at: datetime

    model_config = {"from_attributes": True}


class ExampleResourceListResponse(BaseModel):
    """Standard paginated list. See CONVENTIONS.md → Pagination."""

    items: list[ExampleResourceResponse]
    total: int
    page: int
    page_size: int
