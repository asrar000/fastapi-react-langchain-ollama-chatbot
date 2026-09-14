#!/usr/bin/env bash
set -e

echo "Scaffolding local coding assistant project..."

# ---- directories ----
mkdir -p \
  backend \
  backend/app \
  backend/app/routers \
  backend/app/services \
  frontend \
  frontend/src \
  frontend/src/components \
  frontend/src/hooks \
  frontend/src/styles \
  frontend/src/utils \
  supabase

# ---- supabase/schema.sql ----
cat > supabase/schema.sql << 'EOF_SUPABASE_SCHEMA_SQL_968064'
-- Run this in the Supabase SQL editor (Project > SQL Editor > New query).

create extension if not exists "uuid-ossp";
create extension if not exists vector;

-- One row per chat thread. `client_id` is the anonymous UUID the frontend
-- generates and stores in localStorage — there is no real auth here.
create table if not exists chat_sessions (
  id uuid primary key default uuid_generate_v4(),
  client_id uuid not null,
  title text not null default 'New chat',
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create index if not exists idx_chat_sessions_client
  on chat_sessions (client_id, updated_at desc);

-- One row per message. `session_id` is how a thread's turns are grouped
-- and fetched together.
create table if not exists messages (
  id uuid primary key default uuid_generate_v4(),
  session_id uuid not null references chat_sessions (id) on delete cascade,
  role text not null check (role in ('user', 'assistant')),
  content text not null,
  created_at timestamptz not null default now()
);

create index if not exists idx_messages_session
  on messages (session_id, created_at);

-- ---------------------------------------------------------------------
-- Optional / stretch: RAG readiness. Not used by the base chat pipeline —
-- only needed if a document-upload + embeddings feature gets added later.
-- `vector(768)` assumes a 768-dim embedding model (e.g. nomic-embed-text
-- via Ollama); change the dimension to match whatever model you embed with.
-- ---------------------------------------------------------------------

create table if not exists document_chunks (
  id uuid primary key default uuid_generate_v4(),
  session_id uuid references chat_sessions (id) on delete cascade,
  content text not null,
  embedding vector(768),
  metadata jsonb,
  created_at timestamptz not null default now()
);

create or replace function match_documents (
  query_embedding vector(768),
  match_session_id uuid,
  match_count int default 5
)
returns table (
  id uuid,
  content text,
  similarity float
)
language plpgsql
as $$
begin
  return query
  select
    document_chunks.id,
    document_chunks.content,
    1 - (document_chunks.embedding <=> query_embedding) as similarity
  from document_chunks
  where document_chunks.session_id = match_session_id
  order by document_chunks.embedding <=> query_embedding
  limit match_count;
end;
$$;
EOF_SUPABASE_SCHEMA_SQL_968064

# ---- backend/.env.example ----
cat > backend/.env.example << 'EOF_BACKEND__ENV_EXAMPLE_7F4301'
SUPABASE_URL=https://your-project.supabase.co
# Use the service_role key here (server-side only, never exposed to the
# browser) — the frontend never talks to Supabase directly, only to this API.
SUPABASE_KEY=your-service-role-key
OLLAMA_BASE_URL=http://localhost:11434
OLLAMA_MODEL=qwen2.5-coder:7b
MEMORY_WINDOW_SIZE=8
CORS_ORIGINS=http://localhost:5173
EOF_BACKEND__ENV_EXAMPLE_7F4301

# ---- backend/requirements.txt ----
cat > backend/requirements.txt << 'EOF_BACKEND_REQUIREMENTS_TXT_746768'
fastapi==0.141.1
uvicorn[standard]==0.52.4
langchain==1.4.0
langchain-core==1.6.3
langchain-ollama==1.1.0
supabase==2.31.0
sse-starlette==3.4.11
pydantic==2.13.5
python-dotenv==1.2.3
python-multipart==0.0.32
EOF_BACKEND_REQUIREMENTS_TXT_746768

# ---- backend/app/__init__.py ----
touch backend/app/__init__.py

# ---- backend/app/config.py ----
cat > backend/app/config.py << 'EOF_BACKEND_APP_CONFIG_PY_7F18AD'
import os

from dotenv import load_dotenv

load_dotenv()


class ConfigError(RuntimeError):
    """Raised at startup when required configuration is missing or invalid."""


class Settings:
    def __init__(self) -> None:
        self.SUPABASE_URL = os.getenv("SUPABASE_URL", "").strip()
        self.SUPABASE_KEY = os.getenv("SUPABASE_KEY", "").strip()
        self.OLLAMA_BASE_URL = os.getenv(
            "OLLAMA_BASE_URL", "http://localhost:11434"
        ).strip()
        self.OLLAMA_MODEL = os.getenv("OLLAMA_MODEL", "qwen2.5-coder:7b").strip()
        self._memory_window_raw = os.getenv("MEMORY_WINDOW_SIZE", "8").strip()
        self.MEMORY_WINDOW_SIZE = 8
        self.CORS_ORIGINS = [
            origin.strip()
            for origin in os.getenv("CORS_ORIGINS", "http://localhost:5173").split(",")
            if origin.strip()
        ]

    def validate(self) -> None:
        """Check configuration up front so bad setup fails at startup.

        Without this, a missing SUPABASE_KEY only surfaces as a confusing
        500 on the first request someone makes.
        """
        problems = []

        if not self.SUPABASE_URL:
            problems.append("SUPABASE_URL is not set")
        elif not self.SUPABASE_URL.startswith("http"):
            problems.append(
                f"SUPABASE_URL looks wrong: {self.SUPABASE_URL!r} "
                "(expected something like https://your-project.supabase.co)"
            )

        if not self.SUPABASE_KEY:
            problems.append("SUPABASE_KEY is not set")

        if not self.OLLAMA_BASE_URL.startswith("http"):
            problems.append(
                f"OLLAMA_BASE_URL looks wrong: {self.OLLAMA_BASE_URL!r} "
                "(expected something like http://localhost:11434)"
            )

        try:
            window = int(self._memory_window_raw)
            if window < 1:
                raise ValueError
            self.MEMORY_WINDOW_SIZE = window
        except ValueError:
            problems.append(
                f"MEMORY_WINDOW_SIZE must be a positive integer, "
                f"got {self._memory_window_raw!r}"
            )

        if not self.CORS_ORIGINS:
            problems.append("CORS_ORIGINS is empty — the frontend will be blocked")

        if problems:
            raise ConfigError(
                "Invalid configuration:\n"
                + "\n".join(f"  - {p}" for p in problems)
                + "\n\nCopy backend/.env.example to backend/.env and fill it in."
            )


settings = Settings()
EOF_BACKEND_APP_CONFIG_PY_7F18AD

# ---- backend/app/database.py ----
cat > backend/app/database.py << 'EOF_BACKEND_APP_DATABASE_PY_6B7A50'
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
EOF_BACKEND_APP_DATABASE_PY_6B7A50

# ---- backend/app/models.py ----
cat > backend/app/models.py << 'EOF_BACKEND_APP_MODELS_PY_0FF144'
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
EOF_BACKEND_APP_MODELS_PY_0FF144

# ---- backend/app/routers/__init__.py ----
touch backend/app/routers/__init__.py

# ---- backend/app/routers/sessions.py ----
cat > backend/app/routers/sessions.py << 'EOF_BACKEND_APP_ROUTERS_SESSIONS_PY_98C7B9'
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
EOF_BACKEND_APP_ROUTERS_SESSIONS_PY_98C7B9

# ---- backend/app/routers/chat.py ----
cat > backend/app/routers/chat.py << 'EOF_BACKEND_APP_ROUTERS_CHAT_PY_D796E1'
import asyncio
import json
from datetime import datetime, timezone

from fastapi import APIRouter
from sse_starlette.sse import EventSourceResponse

from app.database import get_supabase
from app.models import ChatRequest
from app.services.llm_service import stream_chat_response
from app.services.memory_service import get_windowed_history
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

    # Store the user message before calling the LLM. If the local Ollama
    # call fails or the stream dies halfway, the prompt is already durable.
    await asyncio.to_thread(_insert_message, session_id, "user", user_message)

    new_title = _title_from_first_message(user_message) if is_first_message else None
    if is_first_message:
        await asyncio.to_thread(_touch_session, session_id, new_title)

    async def event_generator():
        full_response = ""
        try:
            async for token in stream_chat_response(user_message, history):
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
EOF_BACKEND_APP_ROUTERS_CHAT_PY_D796E1

# ---- backend/app/services/__init__.py ----
touch backend/app/services/__init__.py

# ---- backend/app/services/memory_service.py ----
cat > backend/app/services/memory_service.py << 'EOF_BACKEND_APP_SERVICES_MEMORY_SERVICE_PY_8EB7A5'
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
EOF_BACKEND_APP_SERVICES_MEMORY_SERVICE_PY_8EB7A5

# ---- backend/app/services/session_service.py ----
cat > backend/app/services/session_service.py << 'EOF_BACKEND_APP_SERVICES_SESSION_SERVICE_PY_868602'
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
EOF_BACKEND_APP_SERVICES_SESSION_SERVICE_PY_868602

# ---- backend/app/services/llm_service.py ----
cat > backend/app/services/llm_service.py << 'EOF_BACKEND_APP_SERVICES_LLM_SERVICE_PY_C10DA2'
from langchain_core.messages import AIMessage, HumanMessage
from langchain_core.prompts import ChatPromptTemplate, MessagesPlaceholder
from langchain_ollama import ChatOllama

from app.config import settings

SYSTEM_PROMPT = (
    "You are a helpful coding assistant. Give clear, accurate answers. "
    "When you share code, use fenced markdown code blocks with a language "
    "annotation (e.g. ```python) so it can be syntax-highlighted."
)


def get_llm() -> ChatOllama:
    return ChatOllama(
        model=settings.OLLAMA_MODEL,
        base_url=settings.OLLAMA_BASE_URL,
        streaming=True,
    )


def build_prompt() -> ChatPromptTemplate:
    return ChatPromptTemplate.from_messages(
        [
            ("system", SYSTEM_PROMPT),
            MessagesPlaceholder(variable_name="history"),
            ("human", "{input}"),
        ]
    )


def format_history(messages: list[dict]) -> list:
    """Convert Supabase message rows into LangChain message objects."""
    formatted = []
    for msg in messages:
        if msg["role"] == "user":
            formatted.append(HumanMessage(content=msg["content"]))
        else:
            formatted.append(AIMessage(content=msg["content"]))
    return formatted


async def stream_chat_response(user_input: str, history: list[dict]):
    """Yield response tokens as they arrive from the local Ollama model."""
    chain = build_prompt() | get_llm()

    async for chunk in chain.astream(
        {"input": user_input, "history": format_history(history)}
    ):
        if chunk.content:
            yield chunk.content
EOF_BACKEND_APP_SERVICES_LLM_SERVICE_PY_C10DA2

# ---- backend/app/main.py ----
cat > backend/app/main.py << 'EOF_BACKEND_APP_MAIN_PY_7E270C'
import asyncio
from contextlib import asynccontextmanager

from fastapi import FastAPI
from fastapi.middleware.cors import CORSMiddleware

from app.config import settings
from app.database import check_connection
from app.routers import chat, sessions


@asynccontextmanager
async def lifespan(app: FastAPI):
    # Validate config and connectivity before serving traffic, so a missing
    # key or an un-migrated database fails loudly here instead of turning
    # into a confusing 500 on someone's first message.
    settings.validate()
    await asyncio.to_thread(check_connection)
    print(f"Config OK. Model: {settings.OLLAMA_MODEL} @ {settings.OLLAMA_BASE_URL}")
    yield


app = FastAPI(title="Local LLM Chatbot API", lifespan=lifespan)

app.add_middleware(
    CORSMiddleware,
    allow_origins=settings.CORS_ORIGINS,
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)

app.include_router(chat.router)
app.include_router(sessions.router)


@app.get("/")
async def root():
    return {"status": "ok", "service": "chatbot-api"}


@app.get("/health")
async def health():
    return {"status": "healthy"}
EOF_BACKEND_APP_MAIN_PY_7E270C

# ---- frontend/package.json ----
cat > frontend/package.json << 'EOF_FRONTEND_PACKAGE_JSON_370830'
{
  "name": "chatbot-frontend",
  "private": true,
  "version": "0.1.0",
  "type": "module",
  "scripts": {
    "dev": "vite",
    "build": "vite build",
    "preview": "vite preview"
  },
  "dependencies": {
    "react": "^19.3.0",
    "react-dom": "^19.3.0",
    "react-markdown": "^10.1.0",
    "react-syntax-highlighter": "^16.1.1",
    "remark-gfm": "^4.0.1"
  },
  "devDependencies": {
    "@vitejs/plugin-react": "^6.1.1",
    "vite": "^8.3.0"
  }
}
EOF_FRONTEND_PACKAGE_JSON_370830

# ---- frontend/vite.config.js ----
cat > frontend/vite.config.js << 'EOF_FRONTEND_VITE_CONFIG_JS_89E887'
import { defineConfig } from 'vite'
import react from '@vitejs/plugin-react'

export default defineConfig({
  plugins: [react()],
  server: {
    port: 5173,
  },
})
EOF_FRONTEND_VITE_CONFIG_JS_89E887

# ---- frontend/index.html ----
cat > frontend/index.html << 'EOF_FRONTEND_INDEX_HTML_A12B0E'
<!DOCTYPE html>
<html lang="en">
  <head>
    <meta charset="UTF-8" />
    <meta name="viewport" content="width=device-width, initial-scale=1.0" />
    <title>Local Coding Assistant</title>
  </head>
  <body>
    <div id="root"></div>
    <script type="module" src="/src/main.jsx"></script>
  </body>
</html>
EOF_FRONTEND_INDEX_HTML_A12B0E

# ---- frontend/.env.example ----
cat > frontend/.env.example << 'EOF_FRONTEND__ENV_EXAMPLE_1846ED'
VITE_API_BASE_URL=http://localhost:8000
EOF_FRONTEND__ENV_EXAMPLE_1846ED

# ---- frontend/src/index.css ----
cat > frontend/src/index.css << 'EOF_FRONTEND_SRC_INDEX_CSS_91E522'
@import url('https://fonts.googleapis.com/css2?family=IBM+Plex+Mono:wght@400;500;600&family=IBM+Plex+Sans:wght@400;500;600&display=swap');

:root {
  --font-mono: 'IBM Plex Mono', ui-monospace, 'SF Mono', Consolas, monospace;
  --font-sans: 'IBM Plex Sans', -apple-system, 'Segoe UI', sans-serif;

  --bg: #1c1a17;
  --surface: #26231e;
  --surface-hover: #2e2a23;
  --border: #3d392f;
  --text: #ece6d6;
  --text-muted: #8c8574;
  --accent: #e3a23c;
  --accent-hover: #f0b558;
  --accent-quiet: #6e967d;
}

* {
  box-sizing: border-box;
}

body {
  margin: 0;
  font-family: var(--font-sans);
  background: var(--bg);
  color: var(--text);
}

button,
textarea {
  font-family: inherit;
}

:focus-visible {
  outline: 2px solid var(--accent);
  outline-offset: 2px;
}

@media (prefers-reduced-motion: reduce) {
  * {
    transition: none !important;
    animation: none !important;
  }
}
EOF_FRONTEND_SRC_INDEX_CSS_91E522

# ---- frontend/src/main.jsx ----
cat > frontend/src/main.jsx << 'EOF_FRONTEND_SRC_MAIN_JSX_9B052D'
import React from 'react'
import ReactDOM from 'react-dom/client'
import App from './App.jsx'
import './index.css'

ReactDOM.createRoot(document.getElementById('root')).render(
  <React.StrictMode>
    <App />
  </React.StrictMode>,
)
EOF_FRONTEND_SRC_MAIN_JSX_9B052D

# ---- frontend/src/App.jsx ----
cat > frontend/src/App.jsx << 'EOF_FRONTEND_SRC_APP_JSX_6C8DAC'
import { useEffect } from 'react'
import Sidebar from './components/Sidebar'
import MessageList from './components/MessageList'
import MessageInput from './components/MessageInput'
import { useChat } from './hooks/useChat'
import './styles/App.css'

export default function App() {
  const {
    sessions,
    activeSessionId,
    messages,
    isStreaming,
    loadSessions,
    createSession,
    loadMessages,
    deleteSession,
    sendMessage,
  } = useChat()

  useEffect(() => {
    loadSessions()
  }, [loadSessions])

  return (
    <div className="app">
      <Sidebar
        sessions={sessions}
        activeSessionId={activeSessionId}
        onSelectSession={loadMessages}
        onNewChat={createSession}
        onDeleteSession={deleteSession}
      />
      <div className="chat-canvas">
        <MessageList messages={messages} isStreaming={isStreaming} />
        <MessageInput onSend={sendMessage} disabled={isStreaming} />
      </div>
    </div>
  )
}
EOF_FRONTEND_SRC_APP_JSX_6C8DAC

# ---- frontend/src/utils/session.js ----
cat > frontend/src/utils/session.js << 'EOF_FRONTEND_SRC_UTILS_SESSION_JS_D52F59'
const CLIENT_ID_KEY = 'chatbot_client_id'

export function getClientId() {
  let clientId = localStorage.getItem(CLIENT_ID_KEY)
  if (!clientId) {
    clientId = crypto.randomUUID()
    localStorage.setItem(CLIENT_ID_KEY, clientId)
  }
  return clientId
}
EOF_FRONTEND_SRC_UTILS_SESSION_JS_D52F59

# ---- frontend/src/hooks/useChat.js ----
cat > frontend/src/hooks/useChat.js << 'EOF_FRONTEND_SRC_HOOKS_USECHAT_JS_F5D158'
import { useCallback, useRef, useState } from 'react'
import { getClientId } from '../utils/session'

const API_BASE = import.meta.env.VITE_API_BASE_URL || 'http://localhost:8000'

export function useChat() {
  const [sessions, setSessions] = useState([])
  const [activeSessionId, setActiveSessionId] = useState(null)
  const [messages, setMessages] = useState([])
  const [isStreaming, setIsStreaming] = useState(false)
  const streamingContentRef = useRef('')

  const loadSessions = useCallback(async () => {
    const clientId = getClientId()
    const res = await fetch(`${API_BASE}/api/sessions/?client_id=${clientId}`)
    if (!res.ok) return
    setSessions(await res.json())
  }, [])

  const createSession = useCallback(async () => {
    const clientId = getClientId()
    const res = await fetch(`${API_BASE}/api/sessions/`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ client_id: clientId, title: 'New chat' }),
    })
    const session = await res.json()
    setSessions((prev) => [session, ...prev])
    setActiveSessionId(session.id)
    setMessages([])
    return session.id
  }, [])

  const loadMessages = useCallback(async (sessionId) => {
    const clientId = getClientId()
    setActiveSessionId(sessionId)
    const res = await fetch(
      `${API_BASE}/api/sessions/${sessionId}/messages?client_id=${clientId}`,
    )
    if (!res.ok) return
    setMessages(await res.json())
  }, [])

  const deleteSession = useCallback(
    async (sessionId) => {
      const clientId = getClientId()
      const res = await fetch(
        `${API_BASE}/api/sessions/${sessionId}?client_id=${clientId}`,
        { method: 'DELETE' },
      )
      if (!res.ok) return
      setSessions((prev) => prev.filter((s) => s.id !== sessionId))
      if (sessionId === activeSessionId) {
        setActiveSessionId(null)
        setMessages([])
      }
    },
    [activeSessionId],
  )

  // The backend renames a session from its first message and bumps
  // updated_at. Mirror both locally when the turn finishes, so the sidebar
  // stops showing "New chat" without needing a page reload.
  const syncSessionAfterTurn = useCallback((sessionId, title) => {
    setSessions((prev) => {
      const target = prev.find((s) => s.id === sessionId)
      if (!target) return prev
      const updated = title ? { ...target, title } : target
      return [updated, ...prev.filter((s) => s.id !== sessionId)]
    })
  }, [])

  const sendMessage = useCallback(
    async (content) => {
      const clientId = getClientId()
      let sessionId = activeSessionId
      if (!sessionId) {
        sessionId = await createSession()
      }

      const userMsg = { id: crypto.randomUUID(), role: 'user', content }
      const assistantId = crypto.randomUUID()
      streamingContentRef.current = ''

      setMessages((prev) => [
        ...prev,
        userMsg,
        { id: assistantId, role: 'assistant', content: '' },
      ])
      setIsStreaming(true)

      const updateAssistant = (text) =>
        setMessages((prev) =>
          prev.map((m) => (m.id === assistantId ? { ...m, content: text } : m)),
        )

      try {
        const response = await fetch(`${API_BASE}/api/chat/stream`, {
          method: 'POST',
          headers: { 'Content-Type': 'application/json' },
          body: JSON.stringify({
            session_id: sessionId,
            client_id: clientId,
            message: content,
          }),
        })

        if (!response.ok || !response.body) {
          throw new Error(`Request failed (${response.status})`)
        }

        const reader = response.body.getReader()
        const decoder = new TextDecoder()
        let buffer = ''

        while (true) {
          const { done, value } = await reader.read()
          if (done) break

          buffer += decoder.decode(value, { stream: true })
          // sse-starlette emits CRLF line endings, so split on either form.
          // Splitting only on complete separators leaves any partial event
          // in the buffer for the next chunk.
          const events = buffer.split(/\r?\n\r?\n/)
          buffer = events.pop() ?? ''

          for (const rawEvent of events) {
            if (!rawEvent.trim()) continue

            let eventType = 'message'
            let data = null
            for (const line of rawEvent.split(/\r?\n/)) {
              if (line.startsWith('event:')) eventType = line.slice(6).trim()
              if (line.startsWith('data:')) data = line.slice(5).trim()
            }
            if (!data) continue
            const parsed = JSON.parse(data)

            if (eventType === 'token') {
              streamingContentRef.current += parsed.content
              updateAssistant(streamingContentRef.current)
            } else if (eventType === 'done') {
              syncSessionAfterTurn(sessionId, parsed.title)
            } else if (eventType === 'error') {
              streamingContentRef.current +=
                `\n\n*The local model didn't respond: ${parsed.error}. ` +
                'Check that Ollama is running.*'
              updateAssistant(streamingContentRef.current)
            }
          }
        }
      } catch (err) {
        updateAssistant(
          `*Couldn't reach the backend: ${err.message}. Is the API running?*`,
        )
      } finally {
        setIsStreaming(false)
      }
    },
    [activeSessionId, createSession, syncSessionAfterTurn],
  )

  return {
    sessions,
    activeSessionId,
    messages,
    isStreaming,
    loadSessions,
    createSession,
    loadMessages,
    deleteSession,
    sendMessage,
  }
}
EOF_FRONTEND_SRC_HOOKS_USECHAT_JS_F5D158

# ---- frontend/src/components/CodeBlock.jsx ----
cat > frontend/src/components/CodeBlock.jsx << 'EOF_FRONTEND_SRC_COMPONENTS_CODEBLOCK_JSX_7BD2AF'
import { Prism as SyntaxHighlighter } from 'react-syntax-highlighter'
import { oneDark } from 'react-syntax-highlighter/dist/esm/styles/prism'

// react-markdown (v9+) no longer passes an `inline` flag to the `code`
// component, so block vs. inline has to be inferred: a fenced block always
// carries a `language-xxx` className OR spans multiple lines; a genuine
// inline `code` span never does either.
export function Code({ className, children, ...props }) {
  const match = /language-(\w+)/.exec(className || '')
  const text = String(children).replace(/\n$/, '')
  const isBlock = Boolean(match) || text.includes('\n')

  if (!isBlock) {
    return (
      <code className="inline-code" {...props}>
        {children}
      </code>
    )
  }

  return (
    <SyntaxHighlighter
      style={oneDark}
      language={match ? match[1] : 'text'}
      PreTag="div"
      customStyle={{ borderRadius: '8px', fontSize: '0.85rem', margin: '8px 0' }}
    >
      {text}
    </SyntaxHighlighter>
  )
}

// react-markdown wraps fenced blocks in its own <pre>; since SyntaxHighlighter
// already renders its own wrapper (PreTag above), this just passes the
// <code> child through instead of nesting a second one.
export function Pre({ children }) {
  return <>{children}</>
}
EOF_FRONTEND_SRC_COMPONENTS_CODEBLOCK_JSX_7BD2AF

# ---- frontend/src/components/MessageList.jsx ----
cat > frontend/src/components/MessageList.jsx << 'EOF_FRONTEND_SRC_COMPONENTS_MESSAGELIST_JSX_642043'
import { useEffect, useRef } from 'react'
import Markdown from 'react-markdown'
import remarkGfm from 'remark-gfm'
import { Code, Pre } from './CodeBlock'

export default function MessageList({ messages, isStreaming }) {
  const bottomRef = useRef(null)

  useEffect(() => {
    bottomRef.current?.scrollIntoView({ behavior: 'smooth' })
  }, [messages])

  if (messages.length === 0) {
    return (
      <div className="message-list">
        <div className="empty-state">
          <p>Ask anything — the model runs locally, nothing leaves this machine.</p>
        </div>
      </div>
    )
  }

  return (
    <div className="message-list">
      {messages.map((msg, i) => {
        const isLast = i === messages.length - 1
        const isPending = isLast && msg.role === 'assistant' && isStreaming && !msg.content
        return (
          <div key={msg.id} className={`message message-${msg.role}`}>
            <div className="message-role">{msg.role === 'user' ? 'you' : 'assistant'}</div>
            <div className="message-content">
              {isPending ? (
                <span className="thinking-dots" aria-label="Waiting for response">
                  <span />
                  <span />
                  <span />
                </span>
              ) : (
                <Markdown remarkPlugins={[remarkGfm]} components={{ code: Code, pre: Pre }}>
                  {msg.content}
                </Markdown>
              )}
            </div>
          </div>
        )
      })}
      <div ref={bottomRef} />
    </div>
  )
}
EOF_FRONTEND_SRC_COMPONENTS_MESSAGELIST_JSX_642043

# ---- frontend/src/components/MessageInput.jsx ----
cat > frontend/src/components/MessageInput.jsx << 'EOF_FRONTEND_SRC_COMPONENTS_MESSAGEINPUT_JSX_0A2274'
import { useState } from 'react'

export default function MessageInput({ onSend, disabled }) {
  const [value, setValue] = useState('')

  const submit = (e) => {
    e.preventDefault()
    const trimmed = value.trim()
    if (!trimmed || disabled) return
    onSend(trimmed)
    setValue('')
  }

  const handleKeyDown = (e) => {
    if (e.key === 'Enter' && !e.shiftKey) {
      e.preventDefault()
      submit(e)
    }
  }

  return (
    <form className="message-input" onSubmit={submit}>
      <textarea
        value={value}
        onChange={(e) => setValue(e.target.value)}
        onKeyDown={handleKeyDown}
        placeholder="Ask a question or paste some code..."
        rows={1}
        disabled={disabled}
      />
      <button type="submit" disabled={disabled || !value.trim()}>
        Send
      </button>
    </form>
  )
}
EOF_FRONTEND_SRC_COMPONENTS_MESSAGEINPUT_JSX_0A2274

# ---- frontend/src/components/Sidebar.jsx ----
cat > frontend/src/components/Sidebar.jsx << 'EOF_FRONTEND_SRC_COMPONENTS_SIDEBAR_JSX_2B268A'
export default function Sidebar({
  sessions,
  activeSessionId,
  onSelectSession,
  onNewChat,
  onDeleteSession,
}) {
  return (
    <div className="sidebar">
      <button className="new-chat-btn" onClick={onNewChat}>
        New chat
      </button>
      <div className="session-list">
        {sessions.map((session) => (
          <div
            key={session.id}
            className={`session-row ${session.id === activeSessionId ? 'active' : ''}`}
          >
            <button
              className="session-item"
              onClick={() => onSelectSession(session.id)}
              title={session.title || 'New chat'}
            >
              {session.title || 'New chat'}
            </button>
            <button
              className="session-delete"
              onClick={() => onDeleteSession(session.id)}
              aria-label={`Delete ${session.title || 'chat'}`}
            >
              ×
            </button>
          </div>
        ))}
      </div>
    </div>
  )
}
EOF_FRONTEND_SRC_COMPONENTS_SIDEBAR_JSX_2B268A

# ---- frontend/src/styles/App.css ----
cat > frontend/src/styles/App.css << 'EOF_FRONTEND_SRC_STYLES_APP_CSS_52B15A'
.app {
  display: flex;
  height: 100vh;
  width: 100vw;
  overflow: hidden;
}

/* ---------- sidebar ---------- */

.sidebar {
  width: 260px;
  flex-shrink: 0;
  background: var(--surface);
  border-right: 1px solid var(--border);
  display: flex;
  flex-direction: column;
  padding: 12px;
  gap: 12px;
}

.new-chat-btn {
  background: var(--accent);
  color: #1c1a17;
  border: none;
  border-radius: 8px;
  padding: 10px 14px;
  font-size: 0.9rem;
  font-weight: 600;
  cursor: pointer;
  transition: background 0.15s ease;
}

.new-chat-btn:hover {
  background: var(--accent-hover);
}

.session-list {
  flex: 1;
  overflow-y: auto;
  display: flex;
  flex-direction: column;
  gap: 2px;
}

.session-row {
  display: flex;
  align-items: center;
  border-left: 3px solid transparent;
  border-radius: 0 6px 6px 0;
  transition: background 0.15s ease;
}

.session-row:hover {
  background: var(--surface-hover);
}

.session-row.active {
  background: var(--surface-hover);
  border-left-color: var(--accent);
}

.session-item {
  flex: 1;
  min-width: 0;
  text-align: left;
  background: none;
  border: none;
  padding: 9px 10px;
  font-size: 0.85rem;
  font-family: var(--font-mono);
  color: var(--text-muted);
  white-space: nowrap;
  overflow: hidden;
  text-overflow: ellipsis;
  cursor: pointer;
  transition: color 0.15s ease;
}

.session-row:hover .session-item,
.session-row.active .session-item {
  color: var(--text);
}

.session-delete {
  flex-shrink: 0;
  background: none;
  border: none;
  color: var(--text-muted);
  font-size: 1.1rem;
  line-height: 1;
  padding: 4px 8px;
  cursor: pointer;
  opacity: 0;
  transition: opacity 0.15s ease, color 0.15s ease;
}

.session-row:hover .session-delete {
  opacity: 1;
}

.session-delete:hover {
  color: var(--text);
}

.session-delete:focus-visible {
  opacity: 1;
}

/* ---------- chat canvas ---------- */

.chat-canvas {
  flex: 1;
  display: flex;
  flex-direction: column;
  min-width: 0;
}

.message-list {
  flex: 1;
  overflow-y: auto;
  padding: 28px 24px;
  display: flex;
  flex-direction: column;
  gap: 24px;
  max-width: 720px;
  margin: 0 auto;
  width: 100%;
}

.empty-state {
  margin: auto;
  color: var(--text-muted);
  text-align: center;
  font-size: 0.95rem;
  max-width: 380px;
}

.message {
  display: flex;
  flex-direction: column;
  gap: 4px;
}

.message-role {
  font-family: var(--font-mono);
  font-size: 0.72rem;
  color: var(--text-muted);
  padding-left: 13px;
}

.message-content {
  border-left: 3px solid var(--role-color);
  padding-left: 10px;
  line-height: 1.65;
  font-size: 0.95rem;
  overflow-x: auto;
}

.message-user {
  --role-color: var(--accent);
}

.message-assistant {
  --role-color: var(--accent-quiet);
}

.message-content p {
  margin: 0 0 10px 0;
}

.message-content p:last-child {
  margin-bottom: 0;
}

.message-content ul,
.message-content ol {
  margin: 0 0 10px 0;
  padding-left: 22px;
}

.message-content pre {
  margin: 8px 0;
}

.inline-code {
  background: var(--surface);
  border: 1px solid var(--border);
  padding: 1px 5px;
  border-radius: 4px;
  font-size: 0.87em;
  font-family: var(--font-mono);
}

.thinking-dots {
  display: inline-flex;
  gap: 4px;
  padding: 4px 0;
}

.thinking-dots span {
  width: 6px;
  height: 6px;
  border-radius: 50%;
  background: var(--text-muted);
  animation: thinking-pulse 1.1s ease-in-out infinite;
}

.thinking-dots span:nth-child(2) {
  animation-delay: 0.15s;
}

.thinking-dots span:nth-child(3) {
  animation-delay: 0.3s;
}

@keyframes thinking-pulse {
  0%, 80%, 100% { opacity: 0.25; }
  40% { opacity: 1; }
}

/* ---------- input bar ---------- */

.message-input {
  display: flex;
  gap: 10px;
  align-items: flex-end;
  padding: 14px 24px 22px;
  max-width: 720px;
  margin: 0 auto;
  width: 100%;
  box-sizing: border-box;
}

.message-input textarea {
  flex: 1;
  background: var(--surface);
  border: 1px solid var(--border);
  border-radius: 10px;
  padding: 11px 13px;
  color: var(--text);
  font-size: 0.92rem;
  resize: none;
  outline: none;
  transition: border-color 0.15s ease;
}

.message-input textarea:focus {
  border-color: var(--accent);
}

.message-input textarea::placeholder {
  color: var(--text-muted);
}

.message-input button {
  background: var(--accent);
  color: #1c1a17;
  border: none;
  border-radius: 10px;
  padding: 0 20px;
  height: 42px;
  font-weight: 600;
  font-size: 0.9rem;
  cursor: pointer;
  transition: background 0.15s ease;
}

.message-input button:hover:not(:disabled) {
  background: var(--accent-hover);
}

.message-input button:disabled {
  background: var(--border);
  color: var(--text-muted);
  cursor: not-allowed;
}

/* ---------- responsive ---------- */

@media (max-width: 640px) {
  .sidebar {
    width: 76px;
    padding: 10px 8px;
  }

  .session-item {
    font-size: 0;
    padding: 10px 4px;
  }

  .session-item::first-letter {
    font-size: 0.8rem;
  }

  .session-delete {
    display: none;
  }

  .new-chat-btn {
    padding: 10px 6px;
    font-size: 0;
  }

  .new-chat-btn::before {
    content: '+';
    font-size: 1.1rem;
  }

  .message-list,
  .message-input {
    padding-left: 14px;
    padding-right: 14px;
  }
}
EOF_FRONTEND_SRC_STYLES_APP_CSS_52B15A

# ---- .gitignore ----
cat > .gitignore << 'EOF__GITIGNORE_A5CC29'
# Python
__pycache__/
*.pyc
backend/venv/
backend/.venv/
backend/.env

# Node
frontend/node_modules/
frontend/dist/
frontend/.env

# OS
.DS_Store
EOF__GITIGNORE_A5CC29

# ---- README.md ----
cat > README.md << 'EOF_README_MD_8EC9A0'
# Local Coding Assistant

A chatbot backed by a local Ollama model (`qwen2.5-coder:7b`), FastAPI, LangChain,
Supabase (Postgres), and React.

## Architecture

- **Sessions**: `chat_sessions` + `messages` tables, linked by `session_id`.
  Persisted in Supabase, not in memory.
- **Identity**: the frontend generates a UUID on first load and keeps it in
  `localStorage` as `client_id`. Every session-scoped endpoint requires it and
  verifies the session belongs to that client before reading, writing, or
  deleting. See the honest caveat under *Security* below.
- **Memory**: the last `MEMORY_WINDOW_SIZE` messages (default 8) for a
  session are fetched from Supabase and passed into LangChain's
  `ChatPromptTemplate` as history on every turn.
- **Streaming**: the backend streams tokens over Server-Sent Events as the
  local model generates them; the frontend reads the response body directly
  (not `EventSource`, since the request is a `POST`).
- **Write order**: the user's message is saved *before* the LLM is called,
  and the assistant's reply is saved *after* the stream finishes — so a
  crashed or interrupted generation never loses the prompt.
- **Blocking I/O**: `supabase-py` is a synchronous client, so every database
  call in every route goes through `asyncio.to_thread`. Calling it directly
  inside an async route would block the event loop and stall all concurrent
  requests.
- **Startup validation**: config and database connectivity are checked in the
  FastAPI lifespan hook, so a missing key or an un-migrated database fails
  loudly at boot instead of becoming a confusing 500 on the first message.
- **RAG**: not implemented. `supabase/schema.sql` includes a `document_chunks`
  table and a `match_documents` function so it's schema-ready if you want to
  add document upload + embeddings later.

## Security

`client_id` is an ownership check, **not authentication**. It is a UUID the
browser generates and sends; anyone who obtains it can impersonate that
client. What it does buy you:

- A caller who guesses or scrapes a session UUID cannot read, write to, or
  delete that session without also knowing the owner's `client_id`.
- Session-scoped endpoints return `404` rather than `403` on a mismatch, so
  they don't confirm whether a given session exists.

What it does not do: authenticate anyone. For anything real, swap it for
Supabase Auth, store `user_id` on `chat_sessions`, verify the JWT server-side,
and turn on Row Level Security so the database enforces ownership too.

## Prerequisites

- Python 3.10+
- Node.js 18+
- [Ollama](https://ollama.com) installed and running, with the model pulled:
  ```
  ollama pull qwen2.5-coder:7b
  ```
- A Supabase project (free tier is fine)

## Setup

**1. Database** — open your Supabase project's SQL editor and run
`supabase/schema.sql`.

**2. Backend**

```bash
cd backend
python3 -m venv venv
source venv/bin/activate        # Windows: venv\Scripts\activate
pip install -r requirements.txt
cp .env.example .env            # then fill in SUPABASE_URL / SUPABASE_KEY
uvicorn app.main:app --reload --port 8000
```

If the config is wrong, startup aborts with a message naming what's missing.

**3. Frontend** (separate terminal)

```bash
cd frontend
npm install
cp .env.example .env            # defaults to http://localhost:8000, adjust if needed
npm run dev
```

Open the printed local URL (typically `http://localhost:5173`).

## Notes / trade-offs

- **SSE line endings**: `sse-starlette` emits CRLF, so the frontend parser
  splits on `/\r?\n\r?\n/` rather than `\n\n`. Splitting on `\n\n` alone
  silently yields zero tokens — worth knowing if you adapt this code.
- **Streaming markdown**: code fences render as they're still streaming in,
  so a code block can look unformatted for a moment until its closing
  ` ``` ` arrives. Cosmetic only, not a functional bug.
- **Rate limiting**: intentionally left out. In production, add something
  like `slowapi` or a Redis-backed limiter, and log token counts per session.
- **Sidebar sync**: the backend echoes the auto-generated session title on the
  SSE `done` event, so the sidebar renames itself the moment a first turn
  finishes — no refetch, no reload.
- **No RLS**: the backend uses the service_role key and enforces ownership in
  application code. Row Level Security is the right second layer once there's
  real auth.
EOF_README_MD_8EC9A0

echo ""
echo "Done. Project structure created:"
echo ""
find . -maxdepth 3 -not -path "./.git*" | sort
echo ""
echo "Next steps:"
echo "  1) Run supabase/schema.sql in your Supabase project's SQL editor"
echo "  2) Backend:  cd backend  && python3 -m venv venv && source venv/bin/activate && pip install -r requirements.txt && cp .env.example .env"
echo "              (fill in .env, then: uvicorn app.main:app --reload --port 8000)"
echo "  3) Frontend: cd frontend && npm install && cp .env.example .env && npm run dev"
echo "  4) Pull the model if you haven't: ollama pull qwen2.5-coder:7b"
