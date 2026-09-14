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
