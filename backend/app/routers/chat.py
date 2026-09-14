import asyncio
import json
from datetime import datetime, timezone

from fastapi import APIRouter
from sse_starlette.sse import EventSourceResponse

from app.database import get_supabase
from app.models import ChatRequest
from app.services.llm_service import stream_chat_response
from app.services.memory_service import get_windowed_history
from app.services.rag_service import format_context, retrieve_context
from app.services.session_service import require_session_owner

router = APIRouter(prefix="/api/chat", tags=["chat"])


def _insert_message(session_id: str, role: str, content: str):
    return (
        get_supabase()
        .table("messages")
        .insert({"session_id": session_id, "role": role, "content": content})
        .execute()
    )


def _touch_session(session_id: str, title: str | None = None):
    """Bump updated_at (for sidebar ordering) and optionally set a title."""
    payload = {"updated_at": datetime.now(timezone.utc).isoformat()}
    if title is not None:
        payload["title"] = title
    return (
        get_supabase()
        .table("chat_sessions")
        .update(payload)
        .eq("id", session_id)
        .execute()
    )


def _has_documents(session_id: str) -> bool:
    response = (
        get_supabase()
        .table("documents")
        .select("id")
        .eq("session_id", session_id)
        .limit(1)
        .execute()
    )
    return bool(response.data)


def _title_from_first_message(message: str) -> str:
    text = message.strip().replace("\n", " ")
    return text[:50] + ("..." if len(text) > 50 else "")


@router.post("/stream")
async def chat_stream(payload: ChatRequest):
    # Refuse the request outright if this client doesn't own the session,
    # so a guessed session UUID can't be written to.
    await require_session_owner(payload.session_id, payload.client_id)

    session_id = str(payload.session_id)
    user_message = payload.message

    # Fetch history BEFORE inserting the new message, so it naturally
    # excludes the current turn (no need to trim it back out after).
    history = await asyncio.to_thread(get_windowed_history, payload.session_id)
    is_first_message = len(history) == 0

    # Only pay the embedding round-trip if this session actually has
    # documents; a plain chat session skips retrieval entirely.
    matches = []
    if await asyncio.to_thread(_has_documents, session_id):
        matches = await asyncio.to_thread(
            retrieve_context, payload.session_id, user_message
        )
    context = format_context(matches)

    sources = [
        {
            "filename": m.get("filename") or "document",
            "similarity": round(float(m.get("similarity", 0)), 3),
        }
        for m in matches
    ]

    # Store the user message before calling the LLM. If the local Ollama
    # call fails or the stream dies halfway, the prompt is already durable.
    await asyncio.to_thread(_insert_message, session_id, "user", user_message)

    new_title = _title_from_first_message(user_message) if is_first_message else None
    if is_first_message:
        await asyncio.to_thread(_touch_session, session_id, new_title)

    async def event_generator():
        full_response = ""
        try:
            # Tell the UI which chunks were used before tokens start arriving.
            if sources:
                yield {"event": "sources", "data": json.dumps({"sources": sources})}

            async for token in stream_chat_response(user_message, history, context):
                full_response += token
                yield {"event": "token", "data": json.dumps({"content": token})}

            # Store the assistant response only after the stream completes.
            await asyncio.to_thread(
                _insert_message, session_id, "assistant", full_response
            )
            if not is_first_message:
                await asyncio.to_thread(_touch_session, session_id)

            # Send the title back so the sidebar can update without a reload.
            yield {
                "event": "done",
                "data": json.dumps({"status": "complete", "title": new_title}),
            }

        except Exception as exc:  # local model down, network error, etc.
            yield {"event": "error", "data": json.dumps({"error": str(exc)})}

    return EventSourceResponse(event_generator())
