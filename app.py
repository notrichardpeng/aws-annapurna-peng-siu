from fastapi import FastAPI
from pydantic import BaseModel
from vllm import LLM, SamplingParams

app = FastAPI()

# Load OPT model (adjust size for GPU memory)
llm = LLM(model="facebook/opt-1.3b")

# Request model
class PromptRequest(BaseModel):
    prompt: str

@app.get("/health")
async def health_check():
    return {"status": "ok"}

@app.post("/generate")
async def generate(req: PromptRequest):
    response = llm.generate([req.prompt], SamplingParams(max_tokens=100))
    return {"output": response[0].text}
