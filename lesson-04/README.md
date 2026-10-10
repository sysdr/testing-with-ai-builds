# Lesson 04 — pytest Foundations That Scale

Module 0 · Day 4 · Testing What AI Builds (Systemdr, Inc.)

## Prerequisites

- Lessons 01–03 complete (docker-compose stack running, all 17 endpoints live)
- Python 3.11+

## Install

```bash
pip install pytest pytest-asyncio httpx
```

## Run (host)

```bash
# All tests
make test

# By marker
make test-health
make test-auth

# Override base URL
BASE_URL=http://qatp-staging:8000 pytest tests/ -v
```

## Run (Docker)

Requires the lesson-03 stack already up (`qatp-lesson-03` → api on the shared network).

```bash
# Build the pytest image and run the suite against http://api:8000
make docker-test

# By marker
make docker-test-health
make docker-test-auth
```

The test container is one-shot: it runs pytest and exits. It stays visible in Docker Desktop as **Exited** under `qatp-lesson-04` (not removed). Clear it with `make down`.

## Structure

```
lesson-04/
├── conftest.py          # session-scoped fixtures (base_url, http_client, auth_headers)
├── pytest.ini           # asyncio_mode=auto, markers, log config
├── Dockerfile           # pytest runner image
├── docker-compose.yml   # joins qatp-lesson-03_default, hits api:8000
├── Makefile             # convenience targets
├── reports/             # test output written here by `make test`
└── tests/
    ├── test_health.py   # @pytest.mark.health
    └── test_auth.py     # @pytest.mark.auth
```

## Key concepts

- `http_client` fixture: httpx.AsyncClient, session-scoped, lives for entire pytest run
- `http_client_asgi`: same client mounted on ASGITransport — no port, no socket
- `auth_headers`: one login call per suite, shared across all auth tests
