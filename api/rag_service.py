import os
import lancedb
import requests
from typing import List, Dict, Optional, Any
from sentence_transformers import SentenceTransformer

# --- Configuration ---
LANCEDB_URI = os.getenv("LANCEDB_URI", "s3://vllm-chunking/lancedb")
TABLE_NAME = os.getenv("TABLE_NAME", "chunks")
GROQ_API_KEY = os.getenv("GROQ_API_KEY")
GROQ_MODEL = os.getenv("GROQ_MODEL", "llama-3.3-70b-versatile")
EMBEDDING_MODEL = os.getenv("EMBEDDING_MODEL", "BAAI/bge-small-en-v1.5")
HF_HOME = os.getenv("HF_HOME", os.path.join(os.path.dirname(os.path.dirname(__file__)), ".hf_cache"))

# Ensure HF cache is set
os.environ["HF_HOME"] = HF_HOME

# Global model cache
_model = None

def get_embedding_model():
    global _model
    if _model is None:
        print(f"Loading embedding model: {EMBEDDING_MODEL}...")
        _model = SentenceTransformer(EMBEDDING_MODEL)
    return _model

def get_aws_storage_options():
    # Use environment variables for S3 access
    opts = {
        "aws_access_key_id": os.getenv("AWS_ACCESS_KEY_ID"),
        "aws_secret_access_key": os.getenv("AWS_SECRET_ACCESS_KEY"),
        "aws_region": os.getenv("AWS_REGION", "us-east-1"),
    }
    session_token = os.getenv("AWS_SESSION_TOKEN")
    if session_token:
        opts["aws_session_token"] = session_token
    return opts

def search_lancedb(query_vector: List[float], top_k: int = 5) -> List[Dict]:
    """Search LanceDB on S3 directly."""
    storage_options = get_aws_storage_options()
    db = lancedb.connect(LANCEDB_URI, storage_options=storage_options)
    table = db.open_table(TABLE_NAME)
    
    results = table.search(query_vector).limit(top_k).to_list()
    return results

def build_rag_prompt(query: str, contexts: List[str], history: Optional[List[Dict[str, str]]] = None) -> List[Dict[str, str]]:
    """Build a chat-style prompt with history and context."""
    system_content = (
        "You are a helpful research assistant specializing in medical and viral research (CORD-19 dataset). "
        "Use the following excerpts from scientific papers to answer the user's question.\n\n"
        "GUIDELINES:\n"
        "- Be specific and cite details from the context if available.\n"
        "- If the context doesn't have the exact answer, explain what information is present in the documents.\n"
        "- Maintain a professional and helpful tone.\n\n"
        "CONTEXT EXCERPTS:\n" + "\n---\n".join(contexts)
    )
    
    messages = [
        {
            "role": "system",
            "content": system_content
        }
    ]
    
    # Add history (limited to last 5 turns)
    if history:
        messages.extend(history[-10:]) # 5 turns = 10 messages
        
    # Add current query
    messages.append({"role": "user", "content": query})
    return messages

def call_groq(messages: List[Dict[str, str]]) -> str:
    """Call Groq API directly."""
    url = "https://api.groq.com/openai/v1/chat/completions"
    headers = {
        "Authorization": f"Bearer {GROQ_API_KEY}",
        "Content-Type": "application/json"
    }
    payload = {
        "model": GROQ_MODEL,
        "messages": messages,
        "temperature": 0.2,
        "max_tokens": 1024
    }
    
    response = requests.post(url, headers=headers, json=payload, timeout=60)
    response.raise_for_status()
    return response.json()["choices"][0]["message"]["content"]

def rag_chat(query: str, history: Optional[List[Dict[str, str]]] = None) -> Dict[str, Any]:
    """Manual RAG pipeline implementation."""
    # 1. Embed
    model = get_embedding_model()
    query_vector = model.encode(query).tolist()
    
    # 2. Retrieve (increased top_k for better context)
    results = search_lancedb(query_vector, top_k=10)
    contexts = [r.get("chunk_text", "") for r in results]
    sources = list({r.get("source", "unknown") for r in results})
    
    # 3. Prompt & Generate
    prompt_messages = build_rag_prompt(query, contexts, history)
    answer = call_groq(prompt_messages)
    
    # 4. Format sources for frontend
    formatted_sources = []
    for r in results:
        formatted_sources.append({
            "text": r.get("chunk_text", "")[:300],
            "metadata": {
                "source": r.get("source", "unknown"),
                "title": r.get("title", "unknown"),
                "doc_id": r.get("doc_id", "unknown")
            }
        })
    
    return {
        "query": query,
        "answer": answer,
        "contexts": contexts,
        "sources": formatted_sources
    }

def rag_query(query: str, top_k: int = 5) -> Dict[str, Any]:
    return rag_chat(query)
