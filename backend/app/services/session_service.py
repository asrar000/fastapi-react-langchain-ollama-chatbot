import asyncio
from uuid import UUID

from fastapi import HTTPException

from app.database import get_supabase


def _fetch_owned_session(session_id: UUID, client_id: UUID):
    response = (
        get_supabase()
        .table("chat_sessions")
        .select("id, client_id, title")
        .eq("id", str(session_id))
        .eq("client_id", str(client_id))
        .limit(1)
        .execute()
    )
    rows = response.data or []
    return rows[0] if rows else None


async def require_session_owner(session_id: UUID, client_id: UUID) -> dict:
    """Confirm this client_id owns this session, or refuse the request.

    This is an ownership check, not authentication — client_id is a UUID the
    browser generates and anyone could send. It stops a caller who guesses a
    session UUID from reading or deleting someone else's thread, but it is
    not a substitute for real auth (see README).
    """
    session = await asyncio.to_thread(_fetch_owned_session, session_id, client_id)
    if session is None:
        # 404 rather than 403: don't reveal whether the session exists.
        raise HTTPException(status_code=404, detail="Session not found")
    return session
