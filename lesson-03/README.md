# Lesson 03 — QATP-App: The AI Layer

The Lesson 2 backend plus a retrieval-augmented `/chat` route: Ollama embeds the
question with nomic-embed-text, Chroma finds the three nearest products, and
llama3.2:3b answers from them. Every answer returns its evidence: model,
prompt version, sources with distances, token counts, done_reason and timings.

| Route            | What it does                                              |
|------------------|-----------------------------------------------------------|
| POST /chat       | Answer a product question; 503 if Ollama or Chroma is down |
| POST /ai/reindex | Re-embed every product into Chroma                         |
| GET /ai/status   | Models present, Chroma reachable, products indexed         |

Needs about 6 GB of free RAM and 3 GB of disk for the models. The first `up`
downloads them once into the `ollama-models` volume.

## Run

    make up        # first run pulls llama3.2:3b and nomic-embed-text
    make status    # "ready": true
    make ask Q="Which product has a privacy shutter?"
    make test      # 16 passed (8 from Lesson 2, 8 new)
    make down

Every answer is appended to reports/chat_log.jsonl.
