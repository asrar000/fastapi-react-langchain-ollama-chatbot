import asyncio
from uuid import UUID

from fastapi import APIRouter, File, HTTPException, Query, UploadFile

from app.config import settings
from app.database import get_supabase
from app.models import DocumentResponse
from app.services.rag_service import (
    SUPPORTED_EXTENSIONS,
    DocumentError,
    ingest_document,
)
from app.services.session_service import require_session_owner

router = APIRouter(prefix="/api/documents", tags=["documents"])


def _select_documents(session_id: UUID):
    return (
        get_supabase()
        .table("documents")
        .select("*")
        .eq("session_id", str(session_id))
        .order("created_at", desc=True)
        .execute()
    )


def _select_document(document_id: UUID, session_id: UUID):
    response = (
        get_supabase()
        .table("documents")
        .select("id")
        .eq("id", str(document_id))
        .eq("session_id", str(session_id))
        .limit(1)
        .execute()
    )
    rows = response.data or []
    return rows[0] if rows else None


def _delete_document(document_id: UUID):
    # document_chunks cascades on document_id, so this clears both.
    return (
        get_supabase()
        .table("documents")
        .delete()
        .eq("id", str(document_id))
        .execute()
    )


@router.post("/", response_model=DocumentResponse)
async def upload_document(
    session_id: UUID = Query(...),
    client_id: UUID = Query(...),
    file: UploadFile = File(...),
):
    await require_session_owner(session_id, client_id)

    filename = file.filename or "upload"
    if not any(filename.lower().endswith(ext) for ext in SUPPORTED_EXTENSIONS):
        raise HTTPException(
            status_code=400,
            detail=f"Unsupported file type. Accepted: {', '.join(sorted(SUPPORTED_EXTENSIONS))}",
        )

    raw = await file.read()
    max_bytes = settings.MAX_UPLOAD_MB * 1024 * 1024
    if len(raw) > max_bytes:
        raise HTTPException(
            status_code=413,
            detail=f"File is larger than the {settings.MAX_UPLOAD_MB}MB limit.",
        )
    if not raw:
        raise HTTPException(status_code=400, detail="That file is empty.")

    try:
        document = await asyncio.to_thread(ingest_document, session_id, filename, raw)
    except DocumentError as exc:
        raise HTTPException(status_code=400, detail=str(exc)) from exc
    except RuntimeError as exc:
        raise HTTPException(status_code=503, detail=str(exc)) from exc

    return document


@router.get("/", response_model=list[DocumentResponse])
async def list_documents(session_id: UUID = Query(...), client_id: UUID = Query(...)):
    await require_session_owner(session_id, client_id)
    response = await asyncio.to_thread(_select_documents, session_id)
    return response.data or []


@router.delete("/{document_id}")
async def delete_document(
    document_id: UUID, session_id: UUID = Query(...), client_id: UUID = Query(...)
):
    await require_session_owner(session_id, client_id)
    existing = await asyncio.to_thread(_select_document, document_id, session_id)
    if existing is None:
        raise HTTPException(status_code=404, detail="Document not found")
    await asyncio.to_thread(_delete_document, document_id)
    return {"status": "deleted"}
