#!/usr/bin/env bash
set -euo pipefail

GREEN=$'\033[0;32m'
YELLOW=$'\033[1;33m'
CYAN=$'\033[0;36m'
BOLD=$'\033[1m'
RESET=$'\033[0m'

LESSON_DIR="lesson-05"

echo -e "${CYAN}${BOLD}════════════════════════════════════════════════${RESET}"
echo -e "${BOLD}Module 0 — Build Before You Test${RESET}"
echo -e "${BOLD}Lesson 5 — CI Before the First Real Test${RESET}"
echo -e "${BOLD}Day 5${RESET}"
echo -e "${CYAN}${BOLD}════════════════════════════════════════════════${RESET}"

mkdir -p "$LESSON_DIR"/{app,tests,scripts,reports,.github/workflows}

# ---------------------------------------------------------------- requirements
cat > "$LESSON_DIR/requirements.txt" << 'EOF'
fastapi==0.115.6
uvicorn==0.32.1
asyncpg==0.30.0
redis==5.2.1
httpx==0.28.1
pytest==8.3.4
pytest-asyncio==0.25.0
EOF

# ------------------------------------------------------------------ app slice
cat > "$LESSON_DIR/app/__init__.py" << 'EOF'
"""QATP-App backend package."""
EOF

cat > "$LESSON_DIR/app/main.py" << 'EOF'
"""QATP-App health slice from Lesson 2: the part of the backend CI exercises first."""
from __future__ import annotations

import os

import asyncpg
import redis.asyncio as aioredis
from fastapi import FastAPI
from fastapi.responses import JSONResponse

# Module-level globals so tests can monkeypatch them to simulate an outage.
DATABASE_URL: str = os.environ.get("DATABASE_URL", "postgresql://qatp:qatp@localhost:5432/qatp")
REDIS_URL: str = os.environ.get("REDIS_URL", "redis://localhost:6379/0")

app = FastAPI(title="QATP-App")


async def check_db() -> str:
    """Return "connected" when Postgres answers SELECT 1, otherwise "unreachable"."""
    try:
        conn = await asyncpg.connect(DATABASE_URL, timeout=3)
    except Exception:
        return "unreachable"
    try:
        await conn.fetchval("SELECT 1")
    finally:
        await conn.close()
    return "connected"


async def check_redis() -> str:
    """Return "connected" when Redis answers PING, otherwise "unreachable"."""
    client = aioredis.from_url(REDIS_URL, socket_connect_timeout=3)
    try:
        await client.ping()
    except Exception:
        return "unreachable"
    finally:
        await client.aclose()
    return "connected"


@app.get("/health")
async def health() -> JSONResponse:
    """Report DB and Redis connectivity, returning 503 when either is down."""
    db_status = await check_db()
    redis_status = await check_redis()
    healthy = db_status == "connected" and redis_status == "connected"
    return JSONResponse(
        status_code=200 if healthy else 503,
        content={"db": db_status, "redis": redis_status},
    )
EOF

# ----------------------------------------------------------------- pytest config
cat > "$LESSON_DIR/pytest.ini" << 'EOF'
[pytest]
# auto mode lets plain `async def test_*` functions run without decorators
asyncio_mode = auto
asyncio_default_fixture_loop_scope = function
# makes `from app.main import app` resolve from the project root
pythonpath = .
testpaths = tests
# -ra prints a summary of skipped/failed tests; --strict-markers rejects typo'd markers
addopts = -ra --strict-markers
EOF

# ------------------------------------------------------------------------ tests
cat > "$LESSON_DIR/tests/__init__.py" << 'EOF'
"""QATP-App test package."""
EOF

cat > "$LESSON_DIR/tests/test_health.py" << 'EOF'
"""Health endpoint tests that run against real Postgres and Redis."""
from __future__ import annotations

from collections.abc import AsyncIterator

import httpx
import pytest

from app.main import app


@pytest.fixture
async def client() -> AsyncIterator[httpx.AsyncClient]:
    """Yield an in-process HTTP client bound to the FastAPI app."""
    transport = httpx.ASGITransport(app=app)
    async with httpx.AsyncClient(transport=transport, base_url="http://qatp") as http:
        yield http


async def test_health_returns_200(client: httpx.AsyncClient) -> None:
    """Return 200 when both backing services answer."""
    response = await client.get("/health")
    assert response.status_code == 200


async def test_health_reports_db_connected(client: httpx.AsyncClient) -> None:
    """Report Postgres as connected in the JSON body."""
    body = (await client.get("/health")).json()
    assert body["db"] == "connected"


async def test_health_reports_redis_connected(client: httpx.AsyncClient) -> None:
    """Report Redis as connected in the JSON body."""
    body = (await client.get("/health")).json()
    assert body["redis"] == "connected"


async def test_health_returns_503_when_db_down(
    client: httpx.AsyncClient, monkeypatch: pytest.MonkeyPatch
) -> None:
    """Return 503 and db=unreachable when Postgres refuses connections."""
    monkeypatch.setattr("app.main.DATABASE_URL", "postgresql://qatp:qatp@localhost:1/qatp")
    response = await client.get("/health")
    assert response.status_code == 503
    assert response.json()["db"] == "unreachable"
EOF

cat > "$LESSON_DIR/tests/test_services.py" << 'EOF'
"""Direct connectivity tests that bypass the API and talk to the services."""
from __future__ import annotations

import os

import asyncpg
import redis.asyncio as aioredis

DATABASE_URL = os.environ.get("DATABASE_URL", "postgresql://qatp:qatp@localhost:5432/qatp")
REDIS_URL = os.environ.get("REDIS_URL", "redis://localhost:6379/0")


async def test_postgres_accepts_queries() -> None:
    """Run SELECT 1 against Postgres and expect 1 back."""
    conn = await asyncpg.connect(DATABASE_URL, timeout=3)
    try:
        assert await conn.fetchval("SELECT 1") == 1
    finally:
        await conn.close()


async def test_redis_round_trip() -> None:
    """Write a key to Redis and read the same value back."""
    client = aioredis.from_url(REDIS_URL, decode_responses=True)
    try:
        await client.set("qatp:ci", "ok", ex=30)
        assert await client.get("qatp:ci") == "ok"
    finally:
        await client.aclose()
EOF

# ---------------------------------------------------------------------- scripts
cat > "$LESSON_DIR/scripts/check_junit.py" << 'EOF'
"""Fail the CI job when the JUnit report shows failures or too few executed tests."""
from __future__ import annotations

import argparse
import sys
import xml.etree.ElementTree as ET
from pathlib import Path


def summarize(path: Path) -> dict[str, int]:
    """Sum tests, failures, errors and skipped across every suite in the report."""
    root = ET.parse(path).getroot()
    suites = [root] if root.tag == "testsuite" else list(root.iter("testsuite"))
    totals = {"tests": 0, "failures": 0, "errors": 0, "skipped": 0}
    for suite in suites:
        for key in totals:
            totals[key] += int(suite.get(key, "0"))
    return totals


def main() -> int:
    """Parse arguments, print a one-line verdict and return the process exit code."""
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("report", type=Path)
    parser.add_argument("--min-tests", type=int, default=1)
    args = parser.parse_args()
    if not args.report.is_file():
        print(f"JUNIT FAIL: {args.report} does not exist")
        return 1
    totals = summarize(args.report)
    executed = totals["tests"] - totals["skipped"]
    problems: list[str] = []
    if totals["failures"] or totals["errors"]:
        problems.append(f"{totals['failures']} failures, {totals['errors']} errors")
    if executed < args.min_tests:
        problems.append(f"only {executed} tests executed, floor is {args.min_tests}")
    if problems:
        print("JUNIT FAIL: " + "; ".join(problems))
        return 1
    print(f"JUNIT OK: {executed} tests executed, 0 failures, 0 errors, {totals['skipped']} skipped")
    return 0


if __name__ == "__main__":
    sys.exit(main())
EOF

# ------------------------------------------------------------ local services
cat > "$LESSON_DIR/docker-compose.yml" << 'EOF'
# Local twin of the CI service containers: same images, same credentials, same health checks.
services:
  postgres:
    image: postgres:16-alpine
    environment:
      POSTGRES_USER: qatp
      POSTGRES_PASSWORD: qatp
      POSTGRES_DB: qatp
    ports:
      - "5432:5432"
    healthcheck:
      # `docker compose up --wait` blocks until this passes
      test: ["CMD-SHELL", "pg_isready -U qatp -d qatp"]
      interval: 5s
      timeout: 5s
      retries: 10
  redis:
    image: redis:7-alpine
    ports:
      - "6379:6379"
    healthcheck:
      test: ["CMD", "redis-cli", "ping"]
      interval: 5s
      timeout: 5s
      retries: 10
EOF

# --------------------------------------------------------------------- workflow
cat > "$LESSON_DIR/.github/workflows/ci.yml" << 'EOF'
name: ci

on:
  push:
    branches: [main]
  pull_request:

# Cancel a superseded run when you push again to the same branch.
concurrency:
  group: ci-${{ github.ref }}
  cancel-in-progress: true

permissions:
  contents: read   # least privilege: the job only reads the repo

jobs:
  test:
    runs-on: ubuntu-latest
    timeout-minutes: 10   # a hung service must not burn runner minutes forever
    services:
      postgres:
        image: postgres:16-alpine
        env:
          POSTGRES_USER: qatp
          POSTGRES_PASSWORD: qatp
          POSTGRES_DB: qatp
        ports:
          - 5432:5432   # job runs on the VM, so reach it at localhost:5432
        options: >-
          --health-cmd "pg_isready -U qatp -d qatp"
          --health-interval 5s
          --health-timeout 5s
          --health-retries 10
      redis:
        image: redis:7-alpine
        ports:
          - 6379:6379
        options: >-
          --health-cmd "redis-cli ping"
          --health-interval 5s
          --health-timeout 5s
          --health-retries 10
    env:
      DATABASE_URL: postgresql://qatp:qatp@localhost:5432/qatp
      REDIS_URL: redis://localhost:6379/0
    steps:
      - uses: actions/checkout@v4
      - uses: actions/setup-python@v5
        with:
          python-version: "3.11"
          cache: pip   # keys the cache on requirements.txt
      - name: Install dependencies
        run: pip install -r requirements.txt
      - name: Run pytest
        run: |
          mkdir -p reports
          pytest --junitxml=reports/junit.xml
      - name: Enforce test floor
        run: python scripts/check_junit.py reports/junit.xml --min-tests 6
      - name: Upload JUnit report
        if: always()   # keep the report even when tests fail
        uses: actions/upload-artifact@v4
        with:
          name: junit-report
          path: reports/junit.xml
EOF

# --------------------------------------------------------------------- Makefile
cat > "$LESSON_DIR/Makefile" << 'EOF'
.PHONY: up down venv test check clean

# Start local Postgres and Redis and wait until both are healthy.
up:
	docker compose up -d --wait

# Stop the services and delete their volumes.
down:
	docker compose down -v

# Create the virtualenv and install pinned dependencies.
venv:
	python3 -m venv .venv
	.venv/bin/pip install -q -r requirements.txt

# Run pytest and write the JUnit report CI also produces.
test: venv
	mkdir -p reports
	.venv/bin/pytest --junitxml=reports/junit.xml

# Apply the same test-floor check CI applies.
check:
	.venv/bin/python scripts/check_junit.py reports/junit.xml --min-tests 6

# Remove the virtualenv, reports and caches.
clean:
	rm -rf .venv reports/junit.xml .pytest_cache
EOF

# ------------------------------------------------------------------- housekeeping
cat > "$LESSON_DIR/.gitignore" << 'EOF'
.venv/
__pycache__/
.pytest_cache/
reports/*.xml
EOF

cat > "$LESSON_DIR/reports/.gitkeep" << 'EOF'
# keeps reports/ in git; CI and make test write junit.xml here
EOF

cat > "$LESSON_DIR/README.md" << 'EOF'
# Lesson 5 — CI Before the First Real Test

QATP-App's `/health` endpoint, a six-test pytest suite, and a GitHub Actions
workflow that runs it against real Postgres 16 and Redis 7 service containers.

## Run locally

    make up       # start Postgres and Redis, wait for healthy
    make test     # run pytest, write reports/junit.xml
    make check    # fail unless at least 6 tests executed with zero failures

## Run in CI

    git init -b main
    git add .
    git commit -m "ci: gate main on pytest with real services"
    git remote add origin git@github.com:<your-user>/qatp-app.git
    git push -u origin main

Open the Actions tab and watch the `test` job.

## Files

- `.github/workflows/ci.yml` — the gate
- `scripts/check_junit.py` — fails on failures or on fewer than N executed tests
- `docker-compose.yml` — local twin of the CI service containers
EOF

echo -e "${GREEN}Files written to ./${LESSON_DIR}${RESET}"

# --------------------------------------------------------------------- run_test
run_test() {
  local status=0
  echo -e "${CYAN}Starting Postgres and Redis, then running pytest...${RESET}"
  ( cd "$LESSON_DIR" && docker compose up -d --wait && make test ) || status=$?
  if [[ $status -eq 0 ]]; then
    echo -e "${GREEN}✅ PASSED${RESET} — pytest ran against live Postgres and Redis"
  else
    echo -e "${YELLOW}❌ FAILED${RESET} — pytest exited with status ${status}"
  fi
  return "$status"
}

# ----------------------------------------------------------------- verify_result
verify_result() {
  local report="$LESSON_DIR/reports/junit.xml"
  if [[ ! -f "$report" ]]; then
    echo -e "${YELLOW}VERDICT: ❌ FAILED — ${report} was not written${RESET}"
    return 1
  fi
  if python3 "$LESSON_DIR/scripts/check_junit.py" "$report" --min-tests 6; then
    echo -e "${GREEN}${BOLD}VERDICT: ✅ Lesson 05 CI gate verified — 6 tests executed, zero failures.${RESET}"
  else
    echo -e "${YELLOW}VERDICT: ❌ FAILED — JUnit report did not meet the gate.${RESET}"
    return 1
  fi
}

if [[ "${1:-}" == "--run" ]]; then
  run_test || true
  verify_result || exit 1
fi

# -------------------------------------------------------------------- NEXT STEPS
cat << EOF

${BOLD}${CYAN}NEXT STEPS${RESET}

${BOLD}1.${RESET} Start the services:
     cd ${LESSON_DIR} && make up
   Expected: Container ... Healthy  (one line each for postgres and redis)

${BOLD}2.${RESET} Run the suite:
     make test
   Expected: 6 passed

${BOLD}3.${RESET} Apply the CI floor check locally:
     make check
   Expected: JUNIT OK: 6 tests executed, 0 failures, 0 errors, 0 skipped

${BOLD}4.${RESET} Push and watch CI:
     git init -b main && git add . && git commit -m "ci: gate main on pytest"
     git remote add origin git@github.com:<your-user>/qatp-app.git
     git push -u origin main
   Expected: green check on the "test" job; "junit-report" under Artifacts

${BOLD}5.${RESET} Or run steps 1-3 in one go from the directory holding this script:
     ./setup_lesson_05.sh --run
   Expected: ✅ PASSED, then VERDICT: ✅ Lesson 05 CI gate verified

EOF