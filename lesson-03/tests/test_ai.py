"""Tests for the AI layer. They check structure and evidence, never the exact wording of an answer."""
import json
import os
from collections.abc import Iterator
from pathlib import Path

import httpx
import pytest

BASE_URL = os.getenv("QATP_BASE_URL", "http://localhost:8000")
CHAT_LOG = Path(os.getenv("CHAT_LOG", "reports/chat_log.jsonl"))


@pytest.fixture(scope="module")
def client() -> Iterator[httpx.Client]:
    """Yield a client with a timeout long enough for CPU inference."""
    with httpx.Client(base_url=BASE_URL, timeout=180) as http:
        yield http


@pytest.fixture(scope="module")
def keyboard_answer(client: httpx.Client) -> dict[str, object]:
    """Ask one question once and share the answer between tests, because each call costs seconds."""
    response = client.post("/chat", json={"question": "Do you sell a mechanical keyboard, and how much is it?"})
    assert response.status_code == 200, response.text
    return response.json()


def test_ai_layer_reports_ready(client: httpx.Client) -> None:
    """Both models are pulled, Chroma answers, and every product is indexed."""
    body = client.get("/ai/status").json()
    product_count = len(client.get("/products", params={"limit": 100}).json())
    assert body["ready"] is True, body
    assert body["models_missing"] == []
    assert body["indexed"] == product_count


def test_answer_names_its_model_and_prompt(keyboard_answer: dict[str, object]) -> None:
    """Every answer says which model and which prompt version produced it."""
    assert keyboard_answer["model"].startswith("llama3.2:3b")
    assert keyboard_answer["prompt_version"] == "shop-assistant-v1"
    assert keyboard_answer["answer"].strip() != ""


def test_answer_was_not_cut_off(keyboard_answer: dict[str, object]) -> None:
    """done_reason 'length' means the token cap truncated the answer, which reads fine but is incomplete."""
    assert keyboard_answer["done_reason"] == "stop"
    assert keyboard_answer["tokens"]["completion"] > 0


def test_sources_are_real_products_closest_first(client: httpx.Client, keyboard_answer: dict[str, object]) -> None:
    """Retrieved sources exist in the catalogue, are sorted by distance, and the keyboard ranks first."""
    sources = keyboard_answer["sources"]
    catalogue = {p["id"] for p in client.get("/products", params={"limit": 100}).json()}
    assert 1 <= len(sources) <= 3
    assert {s["product_id"] for s in sources} <= catalogue
    assert [s["distance"] for s in sources] == sorted(s["distance"] for s in sources)
    assert "Keyboard" in sources[0]["name"]


def test_same_question_retrieves_the_same_sources(client: httpx.Client, keyboard_answer: dict[str, object]) -> None:
    """Retrieval is repeatable even where generation is not, so it is the part to pin."""
    again = client.post("/chat", json={"question": "Do you sell a mechanical keyboard, and how much is it?"}).json()
    assert [s["product_id"] for s in again["sources"]] == [s["product_id"] for s in keyboard_answer["sources"]]


def test_every_answer_is_in_the_chat_log(keyboard_answer: dict[str, object]) -> None:
    """The chat log holds the request id with its sources, so a bad answer can be traced afterwards."""
    entries = [json.loads(line) for line in CHAT_LOG.read_text(encoding="utf-8").splitlines()]
    logged = [e for e in entries if e["request_id"] == keyboard_answer["request_id"]]
    assert len(logged) == 1
    assert logged[0]["sources"] == keyboard_answer["sources"]


def test_empty_question_is_rejected_before_the_model_runs(client: httpx.Client) -> None:
    """Validation happens in FastAPI, so an empty question costs nothing."""
    assert client.post("/chat", json={"question": ""}).status_code == 422


def test_spec_documents_the_ai_routes(client: httpx.Client) -> None:
    """The three AI operations are in the spec with stable ids and declared error responses."""
    paths = client.get("/openapi.json").json()["paths"]
    assert paths["/chat"]["post"]["operationId"] == "chat"
    assert {"200", "422", "503", "504"} <= set(paths["/chat"]["post"]["responses"])
    assert paths["/ai/status"]["get"]["operationId"] == "ai_status"
