import uvicorn
import numpy as np
from fastapi import FastAPI, Request
from pydantic import BaseModel
from contextlib import asynccontextmanager
from transformers import AutoTokenizer
from onnxruntime import InferenceSession
from huggingface_hub import hf_hub_download

# --- 1. Define Constants ---

MODEL_REPO = "distilgpt2"
# We will use the ONNX model provided by Hugging Face
ONNX_FILE = "onnx/model.onnx"
    
# --- 2. Pydantic Models for Input and Output ---

class PromptInput(BaseModel):
    prompt: str
    max_new_tokens: int = 50  # Add a parameter to control output length

class GenerationOutput(BaseModel):
    prompt: str
    generated_text: str

# --- 3. Model Loading with Lifespan ---

model_state = {}

@asynccontextmanager
async def lifespan(app: FastAPI):
    """
    On startup, load the ONNX model and tokenizer.
    """
    print("Application startup...")
    print("Downloading and loading model and tokenizer...")

    # Download the ONNX model file from the Hugging Face Hub
    # Note: We are using the main distilgpt2 repo, which now hosts ONNX versions
    model_path = hf_hub_download(repo_id=MODEL_REPO, filename=ONNX_FILE)
    
    # Load the ONNX model into an InferenceSession
    # You can add 'CUDAExecutionProvider' if you have a GPU and onnxruntime-gpu
    model_state["session"] = InferenceSession(
        model_path, 
        providers=['CPUExecutionProvider']
    )
    
    # Load the tokenizer
    model_state["tokenizer"] = AutoTokenizer.from_pretrained(MODEL_REPO)
    # Set padding token for batching (if you were to do it)
    model_state["tokenizer"].pad_token = model_state["tokenizer"].eos_token
    
    print("Model and tokenizer loaded successfully.")
    
    yield  # Application runs here

    # --- Shutdown ---
    print("Application shutdown...")
    model_state.clear()


# --- 4. Create FastAPI App ---

app = FastAPI(lifespan=lifespan)

# --- 5. Define API Endpoints ---

@app.get("/")
def read_root():
    return {"status": "ok", "message": "Text Generation API is running."}


@app.post("/generate", response_model=GenerationOutput)
def generate(request: Request, data: PromptInput):
    """
    Main text generation endpoint.
    """
    
    # Get the model and tokenizer from the app state
    session = request.app.state.session
    tokenizer = request.app.state.tokenizer
    
    # --- 1. Preprocess (Tokenize) ---
    # Tokenize the input prompt
    inputs = tokenizer(data.prompt, return_tensors="np")
    input_ids = inputs.input_ids
    
    # Get the names of the ONNX model's inputs
    # This is more robust than hard-coding "input_ids"
    input_names = [inp.name for inp in session.get_inputs()]
    
    # --- 2. Generation Loop (Autoregressive) ---
    # This is the core logic for a text generation model.
    # We feed the model's output back in as its next input.
    
    for _ in range(data.max_new_tokens):
        # Prepare the inputs for the ONNX session
        # This model might just need 'input_ids'
        # More complex models might also need 'attention_mask'
        onnx_inputs = {input_names[0]: input_ids}
        
        # Run the inference
        # The output 'logits' is the first element
        logits = session.run(None, onnx_inputs)[0]
        
        # Get the logits for the *very last* token
        next_token_logits = logits[0, -1, :]
        
        # Find the token with the highest probability (greedy search)
        next_token_id = np.argmax(next_token_logits)
        
        # Stop if we generate the End-of-Text token
        if next_token_id == tokenizer.eos_token_id:
            break
            
        # Append the new token to our input_ids
        # We need to reshape it to (1, 1) to concatenate
        next_token_id_reshaped = np.array([[next_token_id]], dtype=np.int64)
        input_ids = np.concatenate([input_ids, next_token_id_reshaped], axis=1)

    # --- 3. Post-process (Decode) ---
    # Decode the generated token IDs back into a string
    # [0] selects the first (and only) batch
    generated_text = tokenizer.decode(input_ids[0], skip_special_tokens=True)

    # --- 4. Return Response ---
    return GenerationOutput(
        prompt=data.prompt,
        generated_text=generated_text
    )

# --- 6. Run the Application ---

if __name__ == "__main__":
    uvicorn.run(app, host="0.0.0.0", port=8000)