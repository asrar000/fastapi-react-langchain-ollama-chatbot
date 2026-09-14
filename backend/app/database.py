from functools import lru_cache

from supabase import Client, create_client

from app.config import settings


@lru_cache(maxsize=1)
def get_supabase() -> Client:
    """Build the Supabase client lazily.

    Creating it at import time would crash on missing credentials before
    the startup validation in config.py gets a chance to print a useful
    message, so the client is built on first use and cached.
    """
    return create_client(settings.SUPABASE_URL, settings.SUPABASE_KEY)


def check_connection() -> None:
    """Cheap query to confirm the database is reachable and the schema exists."""
    try:
        get_supabase().table("chat_sessions").select("id").limit(1).execute()
    except Exception as exc:
        raise RuntimeError(
            "Could not reach Supabase or query the 'chat_sessions' table.\n"
            f"  Underlying error: {exc}\n"
            "  Check SUPABASE_URL / SUPABASE_KEY in backend/.env, and confirm "
            "you ran supabase/schema.sql in the Supabase SQL editor."
        ) from exc
