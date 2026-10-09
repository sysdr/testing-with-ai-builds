FROM python:3.11-slim
WORKDIR /app
# Install dependencies first so code edits do not invalidate this layer
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt
COPY app ./app
# Tests ship in the image so `make test` needs no Python on the host
COPY tests ./tests
EXPOSE 8000
CMD ["uvicorn", "app.main:app", "--host", "0.0.0.0", "--port", "8000"]
