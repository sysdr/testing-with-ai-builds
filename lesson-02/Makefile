# Recipes use ">" instead of a tab so copy-paste never breaks them
.RECIPEPREFIX := >
.PHONY: up down logs health test spec clean

up:
> docker compose up -d --build --wait

down:
> docker compose down

logs:
> docker compose logs -f api

health:
> curl -s localhost:8000/health | python3 -m json.tool

test:
> docker compose exec -T api pytest tests -v

spec:
> curl -s localhost:8000/openapi.json -o reports/openapi.json
> @echo "Wrote reports/openapi.json"

clean:
> docker compose down -v
> rm -f reports/*.json reports/*.txt
