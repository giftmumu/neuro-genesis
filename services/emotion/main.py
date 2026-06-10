from fastapi import FastAPI, HTTPException
from pydantic import BaseModel
from transformers import AutoTokenizer, AutoModelForSequenceClassification
import torch
import requests
import os

app = FastAPI()

print(">>> [INIT] Loading Emotion Model...")
tokenizer = AutoTokenizer.from_pretrained("uer/roberta-base-finetuned-dianping-chinese")
model = AutoModelForSequenceClassification.from_pretrained("uer/roberta-base-finetuned-dianping-chinese")
print(">>> [SUCCESS] Model Loaded.")

VISUAL_URL = os.getenv("VISUAL_URL", "http://visual-server:8080")

class EmotionRequest(BaseModel):
    text: str
    mode: str = "companion"
    user_id: str = "default"

def update_visual_state(state: str):
    try:
        requests.post(f"{VISUAL_URL}/api/set_state", json={"state": state}, timeout=1)
    except:
        pass

def process_companion(text):
    inputs = tokenizer(text, return_tensors="pt", truncation=True, max_length=512)
    with torch.no_grad():
        outputs = model(**inputs)
    probs = torch.softmax(outputs.logits, dim=-1)
    is_positive = probs[0][1].item() > 0.5
    state = "happy" if is_positive else "sad"
    update_visual_state(state)
    sys_prompt = "你是一个温暖、共情的伴侣。" if is_positive else "你是一个温柔、耐心的倾听者。"
    return {"system_instruction": sys_prompt, "mode": "companion", "visual_state": state}

def process_reflect(text):
    update_visual_state("thinking")
    sys_prompt = "你是用户的数字分身。请模仿用户的语气、用词习惯和思维逻辑来回答，保持冷静宏观的视角。"
    return {"system_instruction": sys_prompt, "mode": "reflect", "visual_state": "thinking"}

@app.post("/analyze")
async def analyze(req: EmotionRequest):
    if req.mode == "companion":
        return process_companion(req.text)
    elif req.mode == "reflect":
        return process_reflect(req.text)
    else:
        raise HTTPException(status_code=400, detail="Invalid mode")

@app.get("/health")
async def health():
    return {"status": "ok"}
