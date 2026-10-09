"""A small async client for the three Ollama endpoints the app uses."""
from dataclasses import dataclass

import httpx


class OllamaError(RuntimeError):
    """Raised when Ollama is unreachable, slow, or missing a model."""


class OllamaTimeout(OllamaError):
    """Raised when Ollama does not finish within the configured timeout."""


@dataclass(frozen=True)
class Generation:
    """One completed answer and the metadata Ollama reports about it."""

    text: str
    model: str
    done_reason: str
    prompt_tokens: int
    completion_tokens: int


class OllamaClient:
    """Calls /api/tags, /api/embed and /api/generate on one Ollama server."""

    def __init__(self, base_url: str, timeout_seconds: float, keep_alive: str) -> None:
        """Create the HTTP client; no request is made until a method is called."""
        self._http = httpx.AsyncClient(base_url=base_url, timeout=timeout_seconds)
        self._keep_alive = keep_alive

    async def models(self) -> list[str]:
        """Return the names of the models already pulled onto the server."""
        try:
            response = await self._http.get("/api/tags", timeout=5)
            response.raise_for_status()
        except httpx.HTTPError as exc:
            raise OllamaError(f"cannot list models: {exc}") from exc
        return [model["name"] for model in response.json().get("models", [])]

    async def embed(self, model: str, texts: list[str]) -> list[list[float]]:
        """Return one embedding vector per input text."""
        payload = {"model": model, "input": texts, "keep_alive": self._keep_alive}
        body = await self._post("/api/embed", payload)
        embeddings = body.get("embeddings", [])
        if len(embeddings) != len(texts):
            raise OllamaError(f"asked for {len(texts)} embeddings, got {len(embeddings)}")
        return embeddings

    async def generate(self, model: str, prompt: str, seed: int, max_tokens: int) -> Generation:
        """Return a single non-streamed answer with temperature 0 and a fixed seed."""
        payload = {
            "model": model,
            "prompt": prompt,
            "stream": False,
            "keep_alive": self._keep_alive,
            "options": {"temperature": 0, "seed": seed, "num_predict": max_tokens},
        }
        body = await self._post("/api/generate", payload)
        return Generation(
            text=body.get("response", "").strip(),
            model=body.get("model", model),
            done_reason=body.get("done_reason", "unknown"),
            prompt_tokens=int(body.get("prompt_eval_count", 0)),
            completion_tokens=int(body.get("eval_count", 0)),
        )

    async def aclose(self) -> None:
        """Close the underlying connection pool."""
        await self._http.aclose()

    async def _post(self, path: str, payload: dict[str, object]) -> dict[str, object]:
        """POST JSON and translate transport failures into OllamaError."""
        try:
            response = await self._http.post(path, json=payload)
        except httpx.TimeoutException as exc:
            raise OllamaTimeout(f"{path} timed out") from exc
        except httpx.HTTPError as exc:
            raise OllamaError(f"{path} unreachable: {exc}") from exc
        if response.status_code == 404:
            raise OllamaError(f"{path}: model not found; run `make pull`")
        if response.status_code >= 400:
            raise OllamaError(f"{path} answered {response.status_code}: {response.text[:200]}")
        return response.json()
