import io
import uuid
from typing import Iterable
from uuid import UUID

from langchain_ollama import OllamaEmbeddings
from langchain_text_splitters import RecursiveCharacterTextSplitter

from app.config import settings
from app.database import get_supabase

SUPPORTED_EXTENSIONS = {".txt", ".md", ".markdown", ".pdf"}


class DocumentError(ValueError):
    """Raised when an upload can't be turned into usable text."""


def get_embeddings() -> OllamaEmbeddings:
    return OllamaEmbeddings(
        model=settings.OLLAMA_EMBED_MODEL, base_url=settings.OLLAMA_BASE_URL
    )


def extract_text(filename: str, raw: bytes) -> str:
    """Pull plain text out of an upload, or explain why we can't."""
    lower = filename.lower()

    if lower.endswith(".pdf"):
        try:
            from pypdf import PdfReader
        except ImportError as exc:  # pragma: no cover
            raise DocumentError("PDF support requires pypdf") from exc
        try:
            reader = PdfReader(io.BytesIO(raw))
            pages = [page.extract_text() or "" for page in reader.pages]
        except Exception as exc:
            raise DocumentError(f"Could not read that PDF: {exc}") from exc
        text = "\n\n".join(pages)
        if not text.strip():
            raise DocumentError(
                "That PDF has no extractable text — it's probably a scan. "
                "OCR it first, or upload a text version."
            )
        return text

    try:
        return raw.decode("utf-8")
    except UnicodeDecodeError:
        # Don't silently mangle a binary file into garbage chunks.
        raise DocumentError(
            "That file isn't valid UTF-8 text. Supported types: "
            + ", ".join(sorted(SUPPORTED_EXTENSIONS))
        )


def chunk_text(text: str) -> list[str]:
    splitter = RecursiveCharacterTextSplitter(
        chunk_size=settings.CHUNK_SIZE,
        chunk_overlap=settings.CHUNK_OVERLAP,
        # Prefer splitting on paragraph, then line, then sentence boundaries,
        # so chunks stay semantically coherent instead of cutting mid-word.
        separators=["\n\n", "\n", ". ", " ", ""],
    )
    return [c for c in splitter.split_text(text) if c.strip()]


def _insert_document(session_id: UUID, filename: str) -> dict:
    response = (
        get_supabase()
        .table("documents")
        .insert({"session_id": str(session_id), "filename": filename})
        .execute()
    )
    if not response.data:
        raise RuntimeError("Failed to create document row")
    return response.data[0]


def _insert_chunks(rows: Iterable[dict]) -> None:
    get_supabase().table("document_chunks").insert(list(rows)).execute()


def _set_chunk_count(document_id: str, count: int) -> None:
    (
        get_supabase()
        .table("documents")
        .update({"chunk_count": count})
        .eq("id", document_id)
        .execute()
    )


def _delete_document_row(document_id: str) -> None:
    get_supabase().table("documents").delete().eq("id", document_id).execute()


def ingest_document(session_id: UUID, filename: str, raw: bytes) -> dict:
    """Chunk, embed, and store an uploaded file. Runs synchronously.

    This blocks until every chunk is embedded, which is fine for the small
    files this accepts. For large documents you'd hand this to a background
    worker and report progress — see README.
    """
    text = extract_text(filename, raw)
    chunks = chunk_text(text)
    if not chunks:
        raise DocumentError("That file appears to be empty.")

    document = _insert_document(session_id, filename)
    document_id = document["id"]

    try:
        vectors = get_embeddings().embed_documents(chunks)
    except Exception as exc:
        # Roll back the document row so a failed embed doesn't leave an
        # orphaned "0 chunks" entry sitting in the sidebar.
        _delete_document_row(document_id)
        raise RuntimeError(
            f"Could not reach the embedding model "
            f"({settings.OLLAMA_EMBED_MODEL}). Run: "
            f"ollama pull {settings.OLLAMA_EMBED_MODEL}\n  Underlying error: {exc}"
        ) from exc

    rows = [
        {
            "id": str(uuid.uuid4()),
            "document_id": document_id,
            "session_id": str(session_id),
            "content": chunk,
            "embedding": vector,
            "metadata": {"filename": filename, "chunk_index": i},
        }
        for i, (chunk, vector) in enumerate(zip(chunks, vectors))
    ]

    try:
        _insert_chunks(rows)
    except Exception:
        _delete_document_row(document_id)
        raise

    _set_chunk_count(document_id, len(rows))
    document["chunk_count"] = len(rows)
    return document


def retrieve_context(session_id: UUID, query: str) -> list[dict]:
    """Find chunks in this session relevant to the query.

    Returns [] on any failure: retrieval is an enhancement, so a broken
    embedding model should degrade to a normal chat turn, not a 500.
    """
    try:
        vector = get_embeddings().embed_query(query)
        response = (
            get_supabase()
            .rpc(
                "match_documents",
                {
                    "query_embedding": vector,
                    "match_session_id": str(session_id),
                    "match_count": settings.RAG_TOP_K,
                    "match_threshold": settings.RAG_MATCH_THRESHOLD,
                },
            )
            .execute()
        )
        return response.data or []
    except Exception as exc:
        print(f"[rag] retrieval skipped: {exc}")
        return []


def format_context(matches: list[dict]) -> str:
    """Render retrieved chunks as a block for the system prompt."""
    if not matches:
        return ""

    parts = []
    for match in matches:
        filename = match.get("filename") or "document"
        parts.append(f"--- from {filename} ---\n{match['content']}")

    return (
        "Use the following excerpts from the user's uploaded documents to "
        "answer. If they don't contain the answer, say so plainly and answer "
        "from your own knowledge instead — do not invent citations.\n\n"
        + "\n\n".join(parts)
    )
