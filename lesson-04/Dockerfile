FROM python:3.11-slim
WORKDIR /app
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt
COPY pytest.ini conftest.py ./
COPY tests ./tests
# reports/ is mounted at runtime so host can read last-run.txt
RUN mkdir -p reports
ENV BASE_URL=http://api:8000
CMD ["pytest", "tests/", "-v", "--tb=short"]
