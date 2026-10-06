.PHONY: up down logs shell ps

up:
	docker compose up -d

down:
	docker compose down

logs:
	docker compose logs -f $(service)

ps:
	docker compose ps

shell:
	docker compose exec app /bin/bash
