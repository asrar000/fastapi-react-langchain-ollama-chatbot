import asyncio
from uuid import UUID

from fastapi import APIRouter, HTTPException, Query

from app.database import get_supabase
from app.models import MessageResponse, SessionCreate, SessionResponse
from app.services.session_service import require_session_owner

router = APIRouter(prefix="/api/sessions", tags=["sessions"])


def _insert_session(client_id: UUID, title: str):
    return (
        get_supabase()
        .table("chat_sessions")
        .insert({"client_id": str(client_id), "title": title})
        .execute()
    )


def _select_sessions(client_id: UUID):
    return (
        get_supabase()
        .table("chat_sessions")
        .select("*")
        .eq("client_id", str(client_id))
        .order("updated_at", desc=True)
        .execute()
    )


def _select_messages(session_id: UUID):
    return (
        get_supabase()
        .table("messages")
        .select("*")
        .eq("session_id", str(session_id))
        .order("created_at")
        .execute()
    )


def _delete_session(session_id: UUID):
    return (
        get_supabase()
        .table("chat_sessions")
        .delete()
        .eq("id", str(session_id))
        .execute()
    )


# Every Supabase call below runs through asyncio.to_thread: supabase-py is a
# synchronous client, so calling it directly inside an async route would block
# the event loop and stall every other in-flight request.


@router.post("/", response_model=SessionResponse)
async def create_session(payload: SessionCreate):
    response = await asyncio.to_thread(
        _insert_session, payload.client_id, payload.title or "New chat"
    )
    if not response.data:
        raise HTTPException(status_code=500, detail="Failed to create session")
    return response.data[0]


@router.get("/", response_model=list[SessionResponse])
async def list_sessions(client_id: UUID):
    response = await asyncio.to_thread(_select_sessions, client_id)
    return response.data or []


@router.get("/{session_id}/messages", response_model=list[MessageResponse])
async def get_session_messages(
    session_id: UUID, client_id: UUID = Query(..., description="Owner of the session")
):
    await require_session_owner(session_id, client_id)
    response = await asyncio.to_thread(_select_messages, session_id)
    return response.data or []


@router.delete("/{session_id}")
async def delete_session(
    session_id: UUID, client_id: UUID = Query(..., description="Owner of the session")
):
    await require_session_owner(session_id, client_id)
    await asyncio.to_thread(_delete_session, session_id)
    return {"status": "deleted"}
