"""Request and response models for the AI routes; they become part of the OpenAPI spec."""
from typing import Literal

from pydantic import BaseModel, Field


class ChatIn(BaseModel):
    """A customer question."""

    question: str = Field(min_length=1, max_length=500)


class ChatSource(BaseModel):
    """One product the answer was allowed to use, with its cosine distance to the question."""

    product_id: int
    name: str
    distance: float


class ChatTokens(BaseModel):
    """Token counts reported by Ollama."""

    prompt: int
    completion: int


class ChatTimings(BaseModel):
    """Milliseconds spent in each stage of the pipeline."""

    embed_ms: float
    retrieve_ms: float
    generate_ms: float
    total_ms: float


class ChatOut(BaseModel):
    """An answer plus the evidence needed to test it."""

    request_id: str
    answer: str
    model: str
    prompt_version: str
    done_reason: str
    sources: list[ChatSource]
    tokens: ChatTokens
    timings: ChatTimings


class ReindexOut(BaseModel):
    """Result of rebuilding the product index."""

    indexed: int
    collection: str
    embed_model: str


class AiStatusOut(BaseModel):
    """Whether the AI layer can answer right now, and if not, why."""

    ready: bool
    ollama: Literal["connected", "unreachable"]
    chroma: Literal["connected", "unreachable"]
    models_present: list[str]
    models_missing: list[str]
    indexed: int
