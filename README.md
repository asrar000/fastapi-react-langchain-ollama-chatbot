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
