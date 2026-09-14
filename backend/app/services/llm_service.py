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
