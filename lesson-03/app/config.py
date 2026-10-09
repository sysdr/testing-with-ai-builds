"""Runtime settings read once from environment variables."""
import os
from dataclasses import dataclass, field
from pathlib import Path


@dataclass(frozen=True)
class Settings:
    """Immutable configuration for the API process."""

    database_url: str = os.getenv("DATABASE_URL", "postgresql://qatp:qatp@db:5432/qatp")
    redis_url: str = os.getenv("REDIS_URL", "redis://redis:6379/0")
    jwt_secret: str = os.getenv("JWT_SECRET", "dev-only-change-me")
    access_ttl: int = int(os.getenv("ACCESS_TTL_SECONDS", "900"))
    refresh_ttl: int = int(os.getenv("REFRESH_TTL_SECONDS", "604800"))
    ollama_url: str = os.getenv("OLLAMA_URL", "http://ollama:11434")
    chat_model: str = os.getenv("CHAT_MODEL", "llama3.2:3b")
    embed_model: str = os.getenv("EMBED_MODEL", "nomic-embed-text")
    ollama_keep_alive: str = os.getenv("OLLAMA_KEEP_ALIVE", "30m")
    llm_timeout_seconds: float = float(os.getenv("LLM_TIMEOUT_SECONDS", "120"))
    max_answer_tokens: int = int(os.getenv("MAX_ANSWER_TOKENS", "200"))
    llm_seed: int = int(os.getenv("LLM_SEED", "42"))
    chroma_host: str = os.getenv("CHROMA_HOST", "chroma")
    chroma_port: int = int(os.getenv("CHROMA_PORT", "8000"))
    chroma_collection: str = os.getenv("CHROMA_COLLECTION", "products")
    retrieval_k: int = int(os.getenv("RETRIEVAL_K", "3"))
    chat_log: Path = field(default_factory=lambda: Path(os.getenv("CHAT_LOG", "reports/chat_log.jsonl")))


settings = Settings()
