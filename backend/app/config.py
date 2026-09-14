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
        self.OLLAMA_EMBED_MODEL = os.getenv(
            "OLLAMA_EMBED_MODEL", "nomic-embed-text"
        ).strip()
        self.CORS_ORIGINS = [
            origin.strip()
            for origin in os.getenv("CORS_ORIGINS", "http://localhost:5173").split(",")
            if origin.strip()
        ]

        # Parsed and range-checked in validate().
        self._ints = {
            "MEMORY_WINDOW_SIZE": (os.getenv("MEMORY_WINDOW_SIZE", "8"), 8),
            "CHUNK_SIZE": (os.getenv("CHUNK_SIZE", "1000"), 1000),
            "CHUNK_OVERLAP": (os.getenv("CHUNK_OVERLAP", "150"), 150),
            "RAG_TOP_K": (os.getenv("RAG_TOP_K", "4"), 4),
            "MAX_UPLOAD_MB": (os.getenv("MAX_UPLOAD_MB", "5"), 5),
        }
        for name, (_, default) in self._ints.items():
            setattr(self, name, default)

        self._threshold_raw = os.getenv("RAG_MATCH_THRESHOLD", "0.3").strip()
        self.RAG_MATCH_THRESHOLD = 0.3

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

        if not self.OLLAMA_EMBED_MODEL:
            problems.append("OLLAMA_EMBED_MODEL is not set")

        for name, (raw, _) in self._ints.items():
            try:
                value = int(raw)
                if value < 1:
                    raise ValueError
                setattr(self, name, value)
            except ValueError:
                problems.append(f"{name} must be a positive integer, got {raw!r}")

        if self.CHUNK_OVERLAP >= self.CHUNK_SIZE:
            problems.append(
                f"CHUNK_OVERLAP ({self.CHUNK_OVERLAP}) must be smaller than "
                f"CHUNK_SIZE ({self.CHUNK_SIZE})"
            )

        try:
            threshold = float(self._threshold_raw)
            if not 0.0 <= threshold <= 1.0:
                raise ValueError
            self.RAG_MATCH_THRESHOLD = threshold
        except ValueError:
            problems.append(
                "RAG_MATCH_THRESHOLD must be a number between 0 and 1, "
                f"got {self._threshold_raw!r}"
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
