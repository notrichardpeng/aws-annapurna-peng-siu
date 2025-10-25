# Lightweight python image
FROM python:3.10-slim

WORKDIR /app

COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY . .

# Expose FastAPI port
EXPOSE 8000

# Runs Uvicorn for FastAPI
CMD ["uvicorn", "app:app", "--host", "0.0.0.0", "--port", "8000"]