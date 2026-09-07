from pydantic import BaseModel


class ErrorDetail(BaseModel):
    """Machine-readable code and safe human-readable message."""

    code: str
    message: str


class ErrorResponse(BaseModel):
    """Unified API error envelope."""

    error: ErrorDetail
