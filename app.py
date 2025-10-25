import uvicorn
import numpy as np
from fastapi import FastAPI, Request
from pydantic import BaseModel
from contextlib import asynccontextmanager
from transformers import AutoTokenizer
from onnxruntime import InferenceSession
from huggingface_hub import hf_hub_download
from prometheus_fastapi_instrumentator import Instrumentator

# --- 1. Define Constants ---

# Using Xenova's ONNX-optimized version of distilgpt2
MODEL_REPO = "Xenova/distilgpt2"
ONNX_FILE = "onnx/decoder_model.onnx"

# Alternative: Use the base model name for tokenizer
TOKENIZER_REPO = "distilgpt2"

# --- 2. Pydantic Models for Input and Output ---

class PromptInput(BaseModel):
    prompt: str
    max_new_tokens: int = 50
    temperature: float = 1.0

class GenerationOutput(BaseModel):
    prompt: str
    generated_text: str
    tokens_generated: int

# --- 3. Model Loading with Lifespan ---

model_state = {}

@asynccontextmanager
async def lifespan(app: FastAPI):
    """
    Asynchronous context manager for FastAPI's lifespan event.
    """
    print("Application startup...")
    print("Downloading and loading DistilGPT2 ONNX model and tokenizer...")

    try:
        # Download the ONNX model file from Xenova's repo
        model_path = hf_hub_download(
            repo_id=MODEL_REPO, 
            filename=ONNX_FILE
        )
        
        # Load the ONNX model into an InferenceSession
        model_state["session"] = InferenceSession(
            model_path, 
            providers=['CPUExecutionProvider']
        )
        
        # Load the tokenizer (using the original distilgpt2)
        model_state["tokenizer"] = AutoTokenizer.from_pretrained(TOKENIZER_REPO)
        
        # Set pad token to eos token (GPT-2 doesn't have a pad token by default)
        if model_state["tokenizer"].pad_token is None:
            model_state["tokenizer"].pad_token = model_state["tokenizer"].eos_token
        
        print("✓ Model and tokenizer loaded successfully.")
        print(f"✓ ONNX model inputs: {[inp.name for inp in model_state['session'].get_inputs()]}")
        print(f"✓ ONNX model outputs: {[out.name for out in model_state['session'].get_outputs()]}")
        
    except Exception as e:
        print(f"Error loading model: {e}")
        print("\nNote: If ONNX file not found, you may need to:")
        print("1. Export the model yourself using optimum-cli")
        print("2. Or use a different pre-converted ONNX model")
        raise
    
    yield
    
    print("Application shutdown...")
    model_state.clear()


# --- 4. Create FastAPI App ---

app = FastAPI(
    title="DistilGPT2 Text Generation API",
    description="ONNX-optimized text generation with Prometheus metrics",
    version="1.0.0",
    lifespan=lifespan
)

# --- 5. Add Prometheus Metrics ---
Instrumentator().instrument(app).expose(app)

# --- 6. Define API Endpoints ---

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
    """
    is_healthy = "session" in model_state and "tokenizer" in model_state
    return {
        "status": "healthy" if is_healthy else "unhealthy",
        "model_loaded": "session" in model_state,
        "tokenizer_loaded": "tokenizer" in model_state
    }


@app.post("/generate", response_model=GenerationOutput)
def generate(request: Request, data: PromptInput):
    """
    Main text generation endpoint using ONNX Runtime.
    Supports temperature-based sampling.
    """
    
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

    # --- 4. Return Response ---
    return GenerationOutput(
        prompt=data.prompt,
        generated_text=generated_text,
        tokens_generated=tokens_generated
    )


# --- 7. Run the Application ---

if __name__ == "__main__":
    uvicorn.run(
        app, 
        host="0.0.0.0", 
        port=8000,
        log_level="info"
    )