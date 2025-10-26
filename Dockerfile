# Base: official vLLM OpenAI-compatible image
FROM vllm/vllm-openai:latest

WORKDIR /app

# Copy your FastAPI app
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt
COPY . .

EXPOSE 8000

# Run FastAPI app
CMD ["uvicorn", "app:app", "--host", "0.0.0.0", "--port", "8000"]
