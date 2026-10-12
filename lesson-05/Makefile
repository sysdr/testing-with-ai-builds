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
