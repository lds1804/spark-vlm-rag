"""
FastAPI application for RAG queries with chat history.

Run locally:
    uvicorn main:app --host 0.0.0.0 --port 8001

Run with Docker:
    docker build -t rag-api .
    docker run -p 8001:8001 rag-api
"""

import os
from fastapi import FastAPI, HTTPException
from fastapi.middleware.cors import CORSMiddleware
from pydantic import BaseModel, Field
from typing import List, Optional, Dict, Any

from rag_service import rag_chat

app = FastAPI(
    title="RAG API",
    description="Retrieval-Augmented Generation API with History Support",
    version="0.2.0"
)

# Enable CORS
app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"], # In production, replace with specific frontend origin
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)


class Message(BaseModel):
    role: str = Field(..., pattern="^(user|assistant)$")
    content: str


class QueryRequest(BaseModel):
    query: str
    history: Optional[List[Message]] = None
    top_k: Optional[int] = 5


class QueryResponse(BaseModel):
    query: str
    answer: str
    contexts: List[str]
    sources: List[Dict[str, Any]]


@app.get("/health")
def health_check():
    return {"status": "ok"}


@app.post("/rag", response_model=QueryResponse)
def ask_question(request: QueryRequest):
    try:
        # Convert Pydantic history to list of dicts if present
        history_data = None
        if request.history:
            history_data = [m.model_dump() for m in request.history]
        
        result = rag_chat(request.query, history=history_data)
        return QueryResponse(**result)
    except Exception as e:
        print(f"API Error: {str(e)}")
        raise HTTPException(status_code=500, detail=str(e))


@app.get("/")
def root():
    return {
        "message": "RAG API with History is running",
        "docs": "/docs",
        "health": "/health"
    }
