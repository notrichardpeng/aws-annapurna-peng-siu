import uvicorn
import numpy as np
from fastapi import FastAPI, Request
from pydantic import BaseModel
from contextlib import asynccontextmanager
from transformers import AutoTokenizer
from onnxruntime import InferenceSession
from huggingface_hub import hf_hub_download
from prometheus_fastapi_instrumentator import Instrumentator  # <-- 1. IMPORT

# ... (Your Pydantic models: PromptInput, GenerationOutput) ...
# ... (Your lifespan function) ...

# --- 4. Create FastAPI App ---
app = FastAPI(lifespan=lifespan)

# --- 5. Add Metrics Endpoint ---
Instrumentator().instrument(app).expose(app)  # <-- 2. HOOK IT TO THE APP

# --- 6. Define API Endpoints ---
@app.get("/")
def read_root():
    return {"status": "ok", "message": "Text Generation API is running."}

# Add a /metrics endpoint for Prometheus
@app.get("/metrics")
def metrics():
    # This endpoint is automatically handled by the instrumentator
    pass  # <-- 3. ADD THIS DUMMY ENDPOINT

# ... (Your /generate endpoint) ...
# ... (Your __main__ block) ...
