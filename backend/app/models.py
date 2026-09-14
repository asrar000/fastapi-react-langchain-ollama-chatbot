from datetime import datetime
from typing import Optional
from uuid import UUID

from pydantic import BaseModel, Field


class SessionCreate(BaseModel):
    client_id: UUID
    title: Optional[str] = "New chat"


class SessionResponse(BaseModel):
    id: UUID
    client_id: UUID
    title: str
    created_at: datetime
    updated_at: datetime


class MessageResponse(BaseModel):
    id: UUID
    session_id: UUID
    role: str
    content: str
    created_at: datetime


class ChatRequest(BaseModel):
    session_id: UUID
    client_id: UUID
    message: str = Field(min_length=1, max_length=20000)


class DocumentResponse(BaseModel):
    id: UUID
    session_id: UUID
    filename: str
    chunk_count: int
    created_at: datetime
