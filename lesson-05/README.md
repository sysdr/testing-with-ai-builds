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
