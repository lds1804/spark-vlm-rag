import os
import json
import lancedb
from llama_index.core import VectorStoreIndex, StorageContext, Settings
from llama_index.vector_stores.lancedb import LanceDBVectorStore
from llama_index.llms.groq import Groq
from llama_index.embeddings.huggingface import HuggingFaceEmbedding

# --- Configuration ---
LANCEDB_URI = os.getenv("LANCEDB_URI") # s3://bucket/path
TABLE_NAME = os.getenv("TABLE_NAME", "chunks")
GROQ_API_KEY = os.getenv("GROQ_API_KEY")
GROQ_MODEL = os.getenv("GROQ_MODEL", "llama3-70b-8192")
EMBEDDING_MODEL = os.getenv("EMBEDDING_MODEL", "BAAI/bge-small-en-v1.5")

# --- Initialize LlamaIndex Components ---
# We use HuggingFaceEmbedding (local) to match our Spark ingestion. 
# In Lambda, this will load from disk/local-storage.
# To keep cold starts low, consider using a cheap Embedding API if 100MB model is too slow.
embed_model = HuggingFaceEmbedding(model_name=EMBEDDING_MODEL)

llm = Groq(model=GROQ_MODEL, api_key=GROQ_API_KEY)

# Global settings for LlamaIndex
Settings.llm = llm
Settings.embed_model = embed_model
Settings.chunk_size = 512

def handler(event, context):
    """AWS Lambda Handler"""
    try:
        # 1. Parse Input
        body = json.loads(event.get("body", "{}"))
        query_text = body.get("query")
        
        if not query_text:
            return {
                "statusCode": 400,
                "body": json.dumps({"error": "Missing 'query' in request body"})
            }

        # 2. Connect to LanceDB on S3
        db = lancedb.connect(LANCEDB_URI)
        vector_store = LanceDBVectorStore(
            uri=LANCEDB_URI, 
            table_name=TABLE_NAME
        )
        
        # 3. Create Index/QueryEngine
        # Note: In production, you might want to cache the index object globally 
        # to reuse across warm invocations.
        storage_context = StorageContext.from_defaults(vector_store=vector_store)
        index = VectorStoreIndex.from_vector_store(
            vector_store, storage_context=storage_context
        )
        
        query_engine = index.as_query_engine(streaming=False)
        
        # 4. Perform RAG
        response = query_engine.query(query_text)
        
        # 5. Format Response
        return {
            "statusCode": 200,
            "headers": {
                "Content-Type": "application/json",
                "Access-Control-Allow-Origin": "*"
            },
            "body": json.dumps({
                "answer": str(response),
                "sources": [
                    {
                        "text": node.get_content(),
                        "metadata": node.metadata
                    } for node in response.source_nodes
                ]
            })
        }

    except Exception as e:
        print(f"Error: {str(e)}")
        return {
            "statusCode": 500,
            "body": json.dumps({"error": "Internal Server Error", "details": str(e)})
        }
