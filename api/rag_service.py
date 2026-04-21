import os
import requests
from typing import List, Dict, Optional

VLLM_HOST = os.getenv("VLLM_HOST", "http://localhost:8000")
VLLM_EMBEDDING_ENDPOINT = f"{VLLM_HOST}/v1/embeddings"
VLLM_CHAT_ENDPOINT = f"{VLLM_HOST}/v1/chat/completions"
EMBEDDING_MODEL = os.getenv("EMBEDDING_MODEL", "BAAI/bge-large-en")
LLM_MODEL = os.getenv("LLM_MODEL", "meta-llama/Llama-2-7b-chat-hf")
VLLM_API_KEY = os.getenv("VLLM_API_KEY", "")

VECTOR_DB_HOST = os.getenv("VECTOR_DB_HOST", "localhost")
VECTOR_DB_PORT = int(os.getenv("VECTOR_DB_PORT", "8080"))
VECTOR_DB_CLASS = os.getenv("VECTOR_DB_CLASS", "DocumentChunk")


def get_query_embedding(query: str) -> List[float]:
    """Generate embedding for user query via vLLM."""
    headers = {"Content-Type": "application/json"}
    if VLLM_API_KEY:
        headers["Authorization"] = f"Bearer {VLLM_API_KEY}"

    payload = {
        "model": EMBEDDING_MODEL,
        "input": [query]
    }

    response = requests.post(
        VLLM_EMBEDDING_ENDPOINT,
        headers=headers,
        json=payload,
        timeout=60
    )
    response.raise_for_status()
    data = response.json()
    return data["data"][0]["embedding"]


def search_vector_db(embedding: List[float], top_k: int = 5) -> List[Dict]:
    """
    Search Weaviate for nearest neighbors.
    Adapt query structure if using Milvus, pgvector or OpenSearch.
    """
    # Weaviate GraphQL example
    query = {
        "query": """
        {
          Get {
            """ + VECTOR_DB_CLASS + """(
              nearVector: {
                vector: """ + str(embedding) + """
              }
              limit: """ + str(top_k) + """
            ) {
              chunk_text
              source
              doc_id
            }
          }
        }
        """
    }

    url = f"http://{VECTOR_DB_HOST}:{VECTOR_DB_PORT}/v1/graphql"
    response = requests.post(url, json=query, timeout=30)
    response.raise_for_status()
    result = response.json()

    if "data" in result and "Get" in result["data"]:
        return result["data"]["Get"].get(VECTOR_DB_CLASS, [])
    return []


def build_prompt(query: str, contexts: List[str]) -> str:
    """Build a simple RAG prompt with retrieved context."""
    context_block = "\n\n".join(
        f"Context {i+1}:\n{ctx}" for i, ctx in enumerate(contexts)
    )
    prompt = (
        "You are a helpful assistant. Use only the provided context to answer the question.\n\n"
        f"{context_block}\n\n"
        f"Question: {query}\n\n"
        "Answer:"
    )
    return prompt


def generate_answer(prompt: str, max_tokens: int = 512, temperature: float = 0.7) -> str:
    """Call vLLM chat completions endpoint."""
    headers = {"Content-Type": "application/json"}
    if VLLM_API_KEY:
        headers["Authorization"] = f"Bearer {VLLM_API_KEY}"

    payload = {
        "model": LLM_MODEL,
        "messages": [
            {"role": "user", "content": prompt}
        ],
        "max_tokens": max_tokens,
        "temperature": temperature
    }

    response = requests.post(
        VLLM_CHAT_ENDPOINT,
        headers=headers,
        json=payload,
        timeout=120
    )
    response.raise_for_status()
    data = response.json()
    return data["choices"][0]["message"]["content"]


def rag_query(query: str, top_k: int = 5) -> Dict:
    """Full RAG pipeline: embed -> retrieve -> generate."""
    embedding = get_query_embedding(query)
    results = search_vector_db(embedding, top_k=top_k)
    contexts = [r["chunk_text"] for r in results]
    prompt = build_prompt(query, contexts)
    answer = generate_answer(prompt)

    return {
        "query": query,
        "answer": answer,
        "contexts": contexts,
        "sources": list({r.get("source", "") for r in results})
    }
