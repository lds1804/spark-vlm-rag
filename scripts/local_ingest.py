import os
os.environ["HF_HOME"] = "/home/lds1804/vLLM-project/.hf_cache"

import pandas as pd
import lancedb
import pyarrow as pa
from sentence_transformers import SentenceTransformer
from tqdm import tqdm

LANCEDB_URI = "s3://vllm-chunking/lancedb"
TABLE_NAME = "chunks"
MODEL_NAME = "BAAI/bge-small-en-v1.5"

def get_aws_storage_options():
    import boto3
    session = boto3.Session()
    creds = session.get_credentials().get_frozen_credentials()
    opts = {
        "aws_access_key_id": creds.access_key,
        "aws_secret_access_key": creds.secret_key,
        "aws_region": session.region_name or "us-east-1",
    }
    if creds.token:
        opts["aws_session_token"] = creds.token
    return opts

def main():
    print("Loading parquet file...")
    # Read the parquet file, but process only a limited number of rows
    # Due to local CPU, let's process 5,000 to significantly increase DB size
    df = pd.read_parquet("sample_chunk.parquet")
    print(f"Total chunks in downloaded file: {len(df)}")
    
    LIMIT = 5000
    df = df.head(LIMIT)
    print(f"Limiting to {LIMIT} chunks for local CPU processing...")
    
    print(f"Loading embedding model: {MODEL_NAME}")
    model = SentenceTransformer(MODEL_NAME)
    
    # We will generate embeddings in batches using tqdm 
    print("Generating embeddings...")
    texts = df["chunk_text"].tolist()
    
    # Encode with progress bar
    embeddings = model.encode(texts, convert_to_numpy=True, show_progress_bar=True)
    
    df["vector"] = list(embeddings)
    
    # Ensure source field is cord19 or similar if not present
    if "source" not in df.columns:
        df["source"] = "cord19"
        
    print(f"Creating PyArrow Table from DataFrame...")
    
    schema = pa.schema([
        pa.field("doc_id", pa.string()),
        pa.field("chunk_id", pa.string()),
        pa.field("chunk_text", pa.string()),
        pa.field("title", pa.string()),
        pa.field("vector", pa.list_(pa.float32(), 384)),
        pa.field("source", pa.string()),
    ])
    
    # Map any differences in column names
    if "cord_uid" in df.columns and ("doc_id" not in df.columns):
        df = df.rename(columns={"cord_uid": "doc_id"})
        
    records = df.to_dict(orient="records")
    
    # Make sure we only take columns from schema
    clean_records = []
    for r in records:
        clean_records.append({
            "doc_id": str(r.get("doc_id", r.get("cord_uid", "uid"))),
            "chunk_id": str(r.get("chunk_id", "")),
            "chunk_text": str(r.get("chunk_text", "")),
            "title": str(r.get("title", "")),
            "vector": r["vector"].tolist(),
            "source": r.get("source", "cord19"),
        })

    print(f"Connecting to LanceDB at {LANCEDB_URI}")
    storage_options = get_aws_storage_options()
    db = lancedb.connect(LANCEDB_URI, storage_options=storage_options)
    
    print(f"Overwriting table '{TABLE_NAME}' with {len(clean_records)} records...")
    table = db.create_table(TABLE_NAME, data=clean_records, schema=schema, mode="overwrite")
        
    print(f"✅ Success! Table '{TABLE_NAME}' created/overwritten with {table.count_rows()} rows total.")
        
    print(f"✅ Success! Table '{TABLE_NAME}' now has {table.count_rows()} rows total.")

if __name__ == "__main__":
    main()
