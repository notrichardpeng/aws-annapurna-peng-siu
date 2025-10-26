# download_model.py

import os
from huggingface_hub import snapshot_download
from transformers import AutoTokenizer

MODEL_REPO = "Xenova/distilgpt2"
TOKENIZER_REPO = "distilgpt2"
LOCAL_CACHE_DIR = "./model_cache" 

def main():
    """Downloads and caches the model and tokenizer files locally."""
    print(f"Starting download and caching for {MODEL_REPO}...")
    
    snapshot_download(
        repo_id=MODEL_REPO,
        local_dir=os.path.join(LOCAL_CACHE_DIR, MODEL_REPO),
        # Only download the ONNX files to keep the image size minimal
        allow_patterns=["onnx/*", "*.json"],
        ignore_patterns=["*.pt", "*.bin", "*.safetensors"] 
    )
        
    tokenizer = AutoTokenizer.from_pretrained(TOKENIZER_REPO)
    tokenizer_path = os.path.join(LOCAL_CACHE_DIR, TOKENIZER_REPO)
    tokenizer.save_pretrained(tokenizer_path)

    print(f"✓ Model and tokenizer files cached successfully in {LOCAL_CACHE_DIR}")

if __name__ == "__main__":
    main()
