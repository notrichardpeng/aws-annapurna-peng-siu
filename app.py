import uvicorn
import numpy as np
from fastapi import FastAPI, Request
from pydantic import BaseModel
from contextlib import asynccontextmanager
from transformers import AutoTokenizer
from onnxruntime import InferenceSession
from huggingface_hub import hf_hub_download
from prometheus_fastapi_instrumentator import Instrumentator  # 1. IMPORT METRICS

# --- 1. Define Constants ---

MODEL_REPO = "distilgpt2"
ONNX_FILE = "onnx/model.onnx"

# --- 2. Pydantic Models for Input and Output ---

class PromptInput(BaseModel):
    prompt: str
    max_new_tokens: int = 50

class GenerationOutput(BaseModel):
    prompt: str
    generated_text: str

# --- 3. Model Loading with Lifespan ---

# This dictionary will hold our loaded model and tokenizer
# It's populated during the 'startup' event.
model_state = {}

@asynccontextmanager
async def lifespan(app: FastAPI):
    """
    Asynchronous context manager for FastAPI's lifespan event.
    This function runs on startup and shutdown.
    """
    print("Application startup...")
    print("Downloading and loading model and tokenizer...")

    # Download the ONNX model file
    model_path = hf_hub_download(repo_id=MODEL_REPO, filename=ONNX_FILE)
    
    # Load the ONNX model into an InferenceSession
    model_state["session"] = InferenceSession(
        model_path, 
        providers=['CPUExecutionProvider']
    )
    
    # Load the tokenizer
    model_state["tokenizer"] = AutoTokenizer.from_pretrained(MODEL_REPO)
    model_state["tokenizer"].pad_token = model_state["tokenizer"].eos_token
    
    print("Model and tokenizer loaded successfully.")
    
    yield  # This 'yield' is where the application runs

    # --- Shutdown ---
    print("Application shutdown...")
    model_state.clear() # Clean up the model state


# --- 4. Create FastAPI App ---

# Initialize the FastAPI app with the lifespan manager
app = FastAPI(lifespan=lifespan)

# --- 5. Add Metrics Endpoint ---
# This line "instruments" your app. It automatically adds
# metrics (like request counts, latency) for Prometheus to scrape.
Instrumentator().instrument(app).expose(app)

# --- 6. Define API Endpoints ---

@app.get("/")
def read_root():
    """
    Root endpoint to check if the API is running.
    """
    return {"status": "ok", "message": "Text Generation API is running."}


@app.get("/metrics")
def metrics():
    """
    This is the endpoint that Prometheus will scrape.
    The Instrumentator handles generating the response for this endpoint.
    """
    pass


@app.post("/generate", response_model=GenerationOutput)
def generate(request: Request, data: PromptInput):
    """
    Main text generation endpoint.
    """
    
    # Get the model and tokenizer from the app state
    # We use request.app.state because the lifespan context manager
    # makes the 'model_state' dictionary available via the app's state.
    session = model_state["session"]
    tokenizer = model_state["tokenizer"]
    
    # --- 1. Preprocess (Tokenize) ---
    inputs = tokenizer(data.prompt, return_tensors="np")
    input_ids = inputs.input_ids
    
    # Get the names of the ONNX model's inputs
    input_names = [inp.name for inp in session.get_inputs()]
    
    # --- 2. Generation Loop (Autoregressive) ---
    for _ in range(data.max_new_tokens):
        # Prepare the inputs for the ONNX session
        onnx_inputs = {input_names[0]: input_ids}
        
        # Run the inference
        logits = session.run(None, onnx_inputs)[0]
        
        # Get the logits for the *very last* token
        next_token_logits = logits[0, -1, :]
        
        # Find the token with the highest probability (greedy search)
        next_token_id = np.argmax(next_token_logits)
        
        # Stop if we generate the End-of-Text token
        if next_token_id == tokenizer.eos_token_id:
            break
            
        # Append the new token to our input_ids
        next_token_id_reshaped = np.array([[next_token_id]], dtype=np.int64)
        input_ids = np.concatenate([input_ids, next_token_id_reshaped], axis=1)

    # --- 3. Post-process (Decode) ---
    generated_text = tokenizer.decode(input_ids[0], skip_special_tokens=True)

    # --- 4. Return Response ---
    return GenerationOutput(
        prompt=data.prompt,
        generated_text=generated_text
    )

# --- 7. Run the Application ---

if __name__ == "__main__":
    """
    This block allows you to run the app directly with `python app.py`
    """
    uvicorn.run(app, host="0.0.0.0", port=8000)
