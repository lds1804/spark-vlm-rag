import os

# vLLM server configuration
VLLM_HOST = os.getenv("VLLM_HOST", "http://localhost:8000")
VLLM_EMBEDDING_ENDPOINT = f"{VLLM_HOST}/v1/embeddings"
VLLM_COMPLETION_ENDPOINT = f"{VLLM_HOST}/v1/completions"
VLLM_API_KEY = os.getenv("VLLM_API_KEY", "")

# Vector database configuration
VECTOR_DB_HOST = os.getenv("VECTOR_DB_HOST", "localhost")
VECTOR_DB_PORT = int(os.getenv("VECTOR_DB_PORT", "8080"))
VECTOR_DB_CLASS = os.getenv("VECTOR_DB_CLASS", "DocumentChunk")
LANCEDB_URI = os.getenv("LANCEDB_URI", "s3://vllm-chunking/lancedb")
LANCEDB_TABLE_NAME = os.getenv("LANCEDB_TABLE_NAME", "chunks")

# Groq configuration
GROQ_API_KEY = os.getenv("GROQ_API_KEY", "")
GROQ_MODEL = os.getenv("GROQ_MODEL", "llama3-70b-8192")

# Spark configuration
SPARK_APP_NAME = os.getenv("SPARK_APP_NAME", "RAG-Embedding-Pipeline")
SPARK_MASTER = os.getenv("SPARK_MASTER", "local[*]")

# Pipeline parameters
CHUNK_SIZE = int(os.getenv("CHUNK_SIZE", "512"))
CHUNK_OVERLAP = int(os.getenv("CHUNK_OVERLAP", "50"))
EMBEDDING_BATCH_SIZE = int(os.getenv("EMBEDDING_BATCH_SIZE", "32"))
EMBEDDING_MODEL = os.getenv("EMBEDDING_MODEL", "BAAI/bge-large-en")

# AWS configuration
AWS_REGION = os.getenv("AWS_REGION", "us-east-1")
S3_INPUT_PATH = os.getenv("S3_INPUT_PATH", "s3a://vllm-chunking/cord19-chunks/")
S3_OUTPUT_PATH = os.getenv("S3_OUTPUT_PATH", "")
