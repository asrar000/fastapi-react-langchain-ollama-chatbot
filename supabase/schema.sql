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
