# Lesson 02 — QATP-App: The Backend

FastAPI backend for the application under test. Seventeen operations, each
with a declared response model and declared error responses.

| Group      | Operations                                         |
|------------|----------------------------------------------------|
| /auth      | register, login, refresh, logout, me               |
| /products  | list, search, get, create, update, delete          |
| /orders    | create, get, list, update status, cancel           |
| /health    | checks Postgres and Redis, 503 if either is down   |

## Run

    make up        # build and start db, redis, api; waits for healthy
    make health    # {"status":"ok","db":"connected","redis":"connected"}
    make test      # 8 passed
    make spec      # writes reports/openapi.json
    make clean     # stop and delete volumes

Swagger UI: http://localhost:8000/docs
