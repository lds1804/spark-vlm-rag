"""
FastAPI application for RAG queries.

Run locally:
    uvicorn main:app --host 0.0.0.0 --port 8001

Run with Docker:
    docker build -t rag-api .
    docker run -p 8001:8001 rag-api
"""

from fastapi import FastAPI, HTTPException
from pydantic import BaseModel
from typing import List, Optional

from rag_service import rag_query

app = FastAPI(
    title="RAG API",
    description="Retrieval-Augmented Generation API using Spark + vLLM",
    version="0.1.0"
)


class QueryRequest(BaseModel):
    query: str
    top_k: Optional[int] = 5


class QueryResponse(BaseModel):
    query: str
    answer: str
    contexts: List[str]
    sources: List[str]


@app.get("/health")
def health_check():
    return {"status": "ok"}


@app.post("/rag", response_model=QueryResponse)
def ask_question(request: QueryRequest):
    try:
        result = rag_query(request.query, top_k=request.top_k)
        return QueryResponse(**result)
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))


@app.get("/")
def root():
    return {
        "message": "RAG API is running",
        "docs": "/docs",
        "health": "/health"
    }
