# Recipes use ">" instead of a tab so copy-paste never breaks them
.RECIPEPREFIX := >
.PHONY: up down logs health status ask reindex pull test spec clean
Q ?= Do you sell a mechanical keyboard?

up:
> docker compose up -d --build --wait

down:
> docker compose down

logs:
> docker compose logs -f api

health:
> curl -s localhost:8000/health | python3 -m json.tool

status:
> curl -s localhost:8000/ai/status | python3 -m json.tool

ask:
> curl -s -X POST localhost:8000/chat -H 'Content-Type: application/json' -d '{"question":"$(Q)"}' | python3 -m json.tool

reindex:
> curl -s -X POST localhost:8000/ai/reindex | python3 -m json.tool

pull:
> @echo "Using host Ollama at http://192.168.1.13:11434 (LAPTOP-RVRF49B4); ensure llama3.2:3b and nomic-embed-text are pulled there."

test:
> docker compose exec -T api pytest tests -v

spec:
> curl -s localhost:8000/openapi.json -o reports/openapi.json
> @echo "Wrote reports/openapi.json"

clean:
> docker compose down -v
> rm -f reports/*.json reports/*.jsonl reports/*.txt
