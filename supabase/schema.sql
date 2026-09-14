-- Run this in the Supabase SQL editor (Project > SQL Editor > New query).
-- Safe to re-run: every statement is idempotent.

create extension if not exists "uuid-ossp";
create extension if not exists vector;

-- One row per chat thread. `client_id` is the anonymous UUID the frontend
-- generates and stores in localStorage — see the Security note in README.
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
-- RAG: uploaded documents and their embedded chunks.
--
-- `vector(768)` matches nomic-embed-text, the default embedding model.
-- If you switch embedding models, change the dimension here AND in the
-- match_documents signature below, then re-upload your documents —
-- embeddings from different models are not comparable.
-- ---------------------------------------------------------------------

-- One row per uploaded file, so the UI can list and delete whole documents.
create table if not exists documents (
  id uuid primary key default uuid_generate_v4(),
  session_id uuid not null references chat_sessions (id) on delete cascade,
  filename text not null,
  chunk_count integer not null default 0,
  created_at timestamptz not null default now()
);

create index if not exists idx_documents_session
  on documents (session_id, created_at desc);

-- One row per embedded chunk. Cascades from both the document and session.
create table if not exists document_chunks (
  id uuid primary key default uuid_generate_v4(),
  document_id uuid not null references documents (id) on delete cascade,
  session_id uuid not null references chat_sessions (id) on delete cascade,
  content text not null,
  embedding vector(768),
  metadata jsonb,
  created_at timestamptz not null default now()
);

create index if not exists idx_document_chunks_session
  on document_chunks (session_id);

-- IVFFlat index for cosine similarity. Only helps once there are enough
-- rows; on a small demo dataset Postgres may still choose a sequential
-- scan, which is fine and correct.
create index if not exists idx_document_chunks_embedding
  on document_chunks using ivfflat (embedding vector_cosine_ops)
  with (lists = 100);

-- Similarity search scoped to one session. `match_threshold` filters out
-- weak matches so unrelated chunks don't get injected into the prompt.
create or replace function match_documents (
  query_embedding vector(768),
  match_session_id uuid,
  match_count int default 4,
  match_threshold float default 0.3
)
returns table (
  id uuid,
  content text,
  filename text,
  similarity float
)
language sql stable
as $$
  select
    dc.id,
    dc.content,
    d.filename,
    1 - (dc.embedding <=> query_embedding) as similarity
  from document_chunks dc
  join documents d on d.id = dc.document_id
  where dc.session_id = match_session_id
    and 1 - (dc.embedding <=> query_embedding) > match_threshold
  order by dc.embedding <=> query_embedding
  limit match_count;
$$;
