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
