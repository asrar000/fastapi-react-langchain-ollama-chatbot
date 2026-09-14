from uuid import UUID

from app.config import settings
from app.database import get_supabase


def get_windowed_history(session_id: UUID, window_size: int = None):
    """Fetch the last `window_size` messages for a session, oldest first.

    Windowed (not full-history) memory keeps the prompt small and fast for
    a local model: we only need enough recent context for coherent
    multi-turn replies, not the entire conversation.
    """
    window_size = window_size or settings.MEMORY_WINDOW_SIZE

    response = (
        get_supabase()
        .table("messages")
        .select("role, content, created_at")
        .eq("session_id", str(session_id))
        .order("created_at", desc=True)
        .limit(window_size)
        .execute()
    )

    messages = response.data or []
    return list(reversed(messages))  # chronological order for the prompt
