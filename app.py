import os
import time
import uvicorn
import psutil
import hashlib
import numpy as np
from functools import lru_cache

from fastapi import FastAPI, Request
from pydantic import BaseModel
from contextlib import asynccontextmanager
from transformers import AutoTokenizer
from onnxruntime import InferenceSession
from huggingface_hub import hf_hub_download
from prometheus_fastapi_instrumentator import Instrumentator
from starlette.middleware.base import BaseHTTPMiddleware
from logging_config import setup_logger

# --- 1. Define Constants ---

MODEL_REPO = "Xenova/distilgpt2"
TOKENIZER_REPO = "distilgpt2"
LOCAL_CACHE_DIR = "./model_cache"
LOCAL_ONNX_PATH = os.path.join(LOCAL_CACHE_DIR, MODEL_REPO, "onnx/decoder_model.onnx")
LOCAL_TOKENIZER_PATH = os.path.join(LOCAL_CACHE_DIR, TOKENIZER_REPO)


# --- 2. Configure Logging ---
logger = setup_logger()

# --- 2.5. Simple Response Cache ---
response_cache = {}

def get_cache_key(prompt: str, max_tokens: int, temp: float) -> str:
    """Generate cache key from request parameters"""
    cache_str = f"{prompt}_{max_tokens}_{temp}"
    return hashlib.md5(cache_str.encode()).hexdigest()


# --- 3. Pydantic Models for Input and Output ---

class PromptInput(BaseModel):
    prompt: str
    max_new_tokens: int = 50
    temperature: float = 1.0

class GenerationOutput(BaseModel):
    prompt: str
    generated_text: str
    tokens_generated: int

# --- 4. Metrics Tracking Middleware ---

class MetricsMiddleware(BaseHTTPMiddleware):
    async def dispatch(self, request: Request, call_next):
        if request.url.path == "/generate":
            start_time = time.time()

            # Capture resource utilization before request
            process = psutil.Process()
            cpu_before = process.cpu_percent()
            memory_before = process.memory_info().rss / 1024 / 1024  # MB

            # Process the request
            response = await call_next(request)

            # Calculate metrics
            latency = time.time() - start_time
            cpu_after = process.cpu_percent()
            memory_after = process.memory_info().rss / 1024 / 1024  # MB

            # Log metrics with structured data
            logger.info(
                "Inference request completed",
                extra={
                    "event": "inference",
                    "latency_ms": round(latency * 1000, 2),
                    "cpu_usage_percent": round((cpu_before + cpu_after) / 2, 2),
                    "memory_mb": round(memory_after, 2),
                    "memory_delta_mb": round(memory_after - memory_before, 2),
                    "path": request.url.path,
                    "method": request.method,
                    "status_code": response.status_code
                }
            )

            return response
        else:
            return await call_next(request)


# --- 5. Model Loading with Lifespan ---

model_state = {}

@asynccontextmanager
async def lifespan(app: FastAPI):
    """
    Asynchronous context manager for FastAPI's lifespan event.
    Model loading now reads from the local filesystem (built by Docker).
    """
    logger.info("Application startup...")
    logger.info(f"Loading DistilGPT2 from local cache: {LOCAL_ONNX_PATH}")

    try:
        # Load the ONNX model from the local path, which was placed here by the Docker build
        model_state["session"] = InferenceSession(
            LOCAL_ONNX_PATH,
            providers=['CPUExecutionProvider']
        )

        # Load the tokenizer from the local path
        model_state["tokenizer"] = AutoTokenizer.from_pretrained(LOCAL_TOKENIZER_PATH)

        # Set pad token to eos token
        if model_state["tokenizer"].pad_token is None:
            model_state["tokenizer"].pad_token = model_state["tokenizer"].eos_token

        # Get ONNX input/output names to verify and use in the loop
        model_state["input_names"] = [inp.name for inp in model_state["session"].get_inputs()]

        logger.info("Model and tokenizer loaded successfully from local cache")
        logger.info("Startup time drastically reduced by pre-caching weights in Docker build")

    except Exception as e:
        logger.error(f"FATAL: Error loading model from local path ({LOCAL_ONNX_PATH})",
                    extra={"error": str(e), "event": "startup_error"})
        raise

    yield

    logger.info("Application shutdown...")
    model_state.clear()


# FastAPI App
app = FastAPI(
    title="DistilGPT2 Text Generation API",
    description="ONNX-optimized text generation with Prometheus metrics and ELK logging",
    version="1.0.0",
    lifespan=lifespan
)

# Add Metrics Middleware
app.add_middleware(MetricsMiddleware)

# Add Prometheus Metrics
Instrumentator().instrument(app).expose(app)

@app.get("/")
def read_root():
    """
    Root endpoint to check if the API is running.
    """
    return {
        "status": "ok",
        "message": "DistilGPT2 Text Generation API is running",
        "model": MODEL_REPO,
        "endpoints": {
            "generate": "/generate",
            "metrics": "/metrics",
            "health": "/health"
        }
    }


@app.get("/health")
def health_check():
    """
    Health check endpoint for monitoring.
    Returns 200 if healthy, 503 if unhealthy.
    """
    is_healthy = "session" in model_state and "tokenizer" in model_state

    if not is_healthy:
        from fastapi import Response
        return Response(
            content='{"status": "unhealthy", "model_loaded": false}',
            status_code=503,
            media_type="application/json"
        )

    return {
        "status": "healthy",
        "model_loaded": "session" in model_state,
        "tokenizer_loaded": "tokenizer" in model_state,
        "cache_size": len(response_cache)
    }


@app.post("/generate", response_model=GenerationOutput)
def generate(request: Request, data: PromptInput):
    """
    Main text generation endpoint using ONNX Runtime.
    Supports temperature-based sampling.
    """
    
    logger.info("Generation request received",
                extra={
                    "event": "generate_request",
                    "prompt_length": len(data.prompt),
                    "max_new_tokens": data.max_new_tokens,
                    "temperature": data.temperature
                })

    # Check cache first
    cache_key = get_cache_key(data.prompt, data.max_new_tokens, data.temperature)
    if cache_key in response_cache:
        logger.info("Cache hit", extra={"event": "cache_hit"})
        return response_cache[cache_key]

    # Get the model and tokenizer from state
    session = model_state["session"]
    tokenizer = model_state["tokenizer"]
    
    # --- 1. Preprocess (Tokenize) ---
    inputs = tokenizer(data.prompt, return_tensors="np")
    input_ids = inputs.input_ids.astype(np.int64)
    attention_mask = inputs.attention_mask.astype(np.int64)
    
    # Get ONNX model input names
    input_names = [inp.name for inp in session.get_inputs()]
    
    tokens_generated = 0
    
    # --- 2. Autoregressive Generation Loop ---
    for _ in range(data.max_new_tokens):
        # Prepare inputs for ONNX session
        onnx_inputs = {
            input_names[0]: input_ids,
        }
        
        # Add attention mask if model expects it
        if len(input_names) > 1 and "attention_mask" in input_names:
            onnx_inputs["attention_mask"] = attention_mask
        
        # Run inference
        outputs = session.run(None, onnx_inputs)
        logits = outputs[0]
        
        # Get logits for the last token
        next_token_logits = logits[0, -1, :]
        
        # Apply temperature
        if data.temperature != 1.0:
            next_token_logits = next_token_logits / data.temperature
        
        # Convert logits to probabilities
        probs = np.exp(next_token_logits) / np.sum(np.exp(next_token_logits))
        
        # Sample from the distribution (or use greedy if temperature is very low)
        if data.temperature < 0.01:
            next_token_id = np.argmax(next_token_logits)
        else:
            next_token_id = np.random.choice(len(probs), p=probs)
        
        # Stop if we generate the EOS token
        if next_token_id == tokenizer.eos_token_id:
            break
        
        # Append the new token
        next_token_id_reshaped = np.array([[next_token_id]], dtype=np.int64)
        input_ids = np.concatenate([input_ids, next_token_id_reshaped], axis=1)
        
        # Update attention mask
        attention_mask = np.concatenate([
            attention_mask, 
            np.ones((1, 1), dtype=np.int64)
        ], axis=1)
        
        tokens_generated += 1

    # --- 3. Decode ---
    generated_text = tokenizer.decode(input_ids[0], skip_special_tokens=True)

    logger.info("Generation completed successfully",
                extra={
                    "event": "generate_success",
                    "tokens_generated": tokens_generated,
                    "output_length": len(generated_text)
                })

    # --- 4. Return Response ---
    response = GenerationOutput(
        prompt=data.prompt,
        generated_text=generated_text,
        tokens_generated=tokens_generated
    )

    # Cache the response (limit cache size to 100 entries)
    if len(response_cache) < 100:
        response_cache[cache_key] = response

    return response


# --- 7. Run the Application ---

if __name__ == "__main__":
    uvicorn.run(
        app, 
        host="0.0.0.0", 
        port=8000,
        log_level="info"
    )