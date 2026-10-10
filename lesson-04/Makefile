.PHONY: test test-auth test-health test-verbose report install up down docker-test docker-test-auth docker-test-health

# Prefer the local venv so `make test` works without activating it
PYTEST := $(shell if [ -x .venv/bin/pytest ]; then echo .venv/bin/pytest; else echo pytest; fi)

install:
	uv venv --clear .venv
	uv pip install --python .venv/bin/python -r requirements.txt

test:
	$(PYTEST) tests/ -v --tb=short 2>&1 | tee reports/last-run.txt

test-auth:
	$(PYTEST) tests/ -m auth -v --tb=short

test-health:
	$(PYTEST) tests/ -m health -v --tb=short

test-verbose:
	$(PYTEST) tests/ -v --tb=long -s

# Docker: pytest one-shot on the qatp-lesson-03 network (api:8000).
# Uses `up` (not `run --rm`) so Docker Desktop keeps qatp-lesson-04 / tests-1
# as Exited after the run — proof the suite ran. `make down` removes it.
up: docker-test

down:
	docker compose down --remove-orphans

docker-test:
	docker compose up --build --force-recreate --exit-code-from tests

docker-test-auth:
	docker compose run --rm --build tests pytest tests/ -m auth -v --tb=short

docker-test-health:
	docker compose run --rm --build tests pytest tests/ -m health -v --tb=short

report:
	@echo "--- Test Reports ---"
	@ls -lh reports/ 2>/dev/null || echo "No reports yet. Run: make test"
