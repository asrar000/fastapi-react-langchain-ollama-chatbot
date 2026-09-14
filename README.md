# Local Coding Assistant

A chatbot backed by a local Ollama model (`qwen2.5-coder:7b`), FastAPI, LangChain,
Supabase (Postgres + pgvector), and React. Includes document-grounded answers (RAG)
using local embeddings — nothing is sent to an external API.

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

## RAG

Upload a `.txt`, `.md`, or `.pdf` and answers in that session get grounded in it.

**Ingest** (`POST /api/documents/`): extract text → split with
`RecursiveCharacterTextSplitter` (`CHUNK_SIZE`/`CHUNK_OVERLAP`, preferring
paragraph then line then sentence boundaries) → embed every chunk with
`nomic-embed-text` via Ollama → store vectors in `document_chunks`.

**Retrieve** (on each chat turn): the session is checked for documents first,
so a plain chat session pays no embedding cost at all. If documents exist, the
question is embedded and passed to the `match_documents` SQL function, which
does a cosine-similarity search scoped to that session and filtered by
`RAG_MATCH_THRESHOLD`. Matches are formatted into the `{context}` slot of the
system prompt.

**Grounding**: the prompt instructs the model to say so plainly when the
excerpts don't contain the answer, rather than inventing citations. The UI
shows which files were used, with similarity scores, under each answer.

Design decisions worth knowing:

- **Documents are scoped per session**, matching the schema. Uploading in one
  chat doesn't leak context into another.
- **Retrieval failures degrade, they don't 500.** If the embedding model is
  unreachable, `retrieve_context` logs and returns `[]`, and the turn proceeds
  as a normal chat. A missing RAG feature shouldn't take the chatbot down.
- **Failed ingests roll back.** If embedding dies partway, the `documents` row
  is deleted so you don't get a phantom "0 chunks" entry in the UI.
- **Braces in retrieved text are safe.** Values substituted into a LangChain
  prompt template aren't re-parsed, so a chunk containing `{...}` (i.e. most
  code) won't break formatting. Verified, not assumed.
- **Embedding dimensions are load-bearing.** `vector(768)` matches
  `nomic-embed-text`. Switching embedding models means changing the dimension
  in `schema.sql` *and* re-uploading every document — vectors from different
  models aren't comparable.

## Security

`client_id` is an ownership check, **not authentication**. It is a UUID the
browser generates and sends; anyone who obtains it can impersonate that
client. What it does buy you:

- A caller who guesses or scrapes a session UUID cannot read, write to, or
  delete that session — or its documents — without the owner's `client_id`.
- Session-scoped endpoints return `404` rather than `403` on a mismatch, so
  they don't confirm whether a given session exists.

What it does not do: authenticate anyone. For anything real, swap it for
Supabase Auth, store `user_id` on `chat_sessions`, verify the JWT server-side,
and turn on Row Level Security so the database enforces ownership too.

## Prerequisites

- Python 3.10+
- Node.js 18+
- [Ollama](https://ollama.com) running, with both models pulled:
  ```
  ollama pull qwen2.5-coder:7b
  ollama pull nomic-embed-text
  ```
- A Supabase project (free tier is fine)

## Setup

**1. Database** — open your Supabase project's SQL editor and run
`supabase/schema.sql`. It's idempotent, so re-run it safely after updates.

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

- **Uploads are synchronous.** The request doesn't return until every chunk is
  embedded, which is why `MAX_UPLOAD_MB` defaults to 5. For larger corpora,
  hand ingestion to a background worker (Celery, ARQ, or a Supabase edge
  function) and poll for status.
- **Scanned PDFs won't work.** Text extraction needs an actual text layer; the
  API returns a clear message rather than silently embedding empty chunks. OCR
  first if you need those.
- **IVFFlat index needs data.** The vector index only helps past a few thousand
  rows; on a small demo set Postgres may sequential-scan, which is correct and
  fast enough.
- **SSE line endings**: `sse-starlette` emits CRLF, so the frontend parser
  splits on `/\r?\n\r?\n/` rather than `\n\n`. Splitting on `\n\n` alone
  silently yields zero tokens — worth knowing if you adapt this code.
- **Streaming markdown**: code fences render as they're still streaming in,
  so a code block can look unformatted for a moment until its closing
  ` ``` ` arrives. Cosmetic only, not a functional bug.
- **Rate limiting**: intentionally left out. In production, add something
  like `slowapi` or a Redis-backed limiter, and log token counts per session.
- **No RLS**: the backend uses the service_role key and enforces ownership in
  application code. Row Level Security is the right second layer once there's
  real auth.
