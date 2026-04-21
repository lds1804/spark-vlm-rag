"""
Spark job for distributed chunking and embedding generation.

Usage:
    spark-submit --master local[*] spark_jobs/embedding_pipeline.py

Environment variables:
    VLLM_HOST: URL of the vLLM server
    S3_INPUT_PATH: s3a://bucket/path/to/input/parquet
    VECTOR_DB_HOST: Weaviate/Milvus host
"""

import requests
import json
from typing import List, Dict
from pyspark.sql import SparkSession
from pyspark.sql.functions import udf, explode, col, monotonically_increasing_id, lit
from pyspark.sql.types import ArrayType, StringType, StructType, StructField, FloatType

import config


def chunk_text(text: str, chunk_size: int = config.CHUNK_SIZE, overlap: int = config.CHUNK_OVERLAP) -> List[str]:
    """
    Fixed-size character chunking with overlap.
    Runs in parallel across Spark executors.
    """
    if not text:
        return []

    chunks = []
    start = 0
    text_len = len(text)

    while start < text_len:
        end = min(start + chunk_size, text_len)
        chunks.append(text[start:end])
        start += chunk_size - overlap
        if start >= end:
            break

    return chunks


def get_embeddings(texts: List[str]) -> List[List[float]]:
    """
    Call vLLM embedding endpoint in batches.
    """
    if not texts:
        return []

    headers = {"Content-Type": "application/json"}
    if config.VLLM_API_KEY:
        headers["Authorization"] = f"Bearer {config.VLLM_API_KEY}"

    embeddings = []
    batch_size = config.EMBEDDING_BATCH_SIZE

    for i in range(0, len(texts), batch_size):
        batch = texts[i:i + batch_size]
        payload = {
            "model": config.EMBEDDING_MODEL,
            "input": batch
        }

        try:
            response = requests.post(
                config.VLLM_EMBEDDING_ENDPOINT,
                headers=headers,
                json=payload,
                timeout=120
            )
            response.raise_for_status()
            data = response.json()
            batch_embeddings = [item["embedding"] for item in data["data"]]
            embeddings.extend(batch_embeddings)
        except Exception as e:
            # In production, log to CloudWatch or Spark logs
            print(f"Error fetching embeddings for batch {i}: {e}")
            # Return zero vectors as fallback so the job does not crash
            zero_vec = [0.0] * 1024  # adjust dimension to your model
            embeddings.extend([zero_vec] * len(batch))

    return embeddings


def main():
    spark = (
        SparkSession.builder
        .appName(config.SPARK_APP_NAME)
        .master(config.SPARK_MASTER)
        .config("spark.sql.adaptive.enabled", "true")
        .config("spark.sql.adaptive.coalescePartitions.enabled", "true")
        .getOrCreate()
    )

    # Example: read raw documents from S3 (Parquet format)
    # Adjust format/path as needed (CSV, JSON, Delta Lake, etc.)
    input_path = config.S3_INPUT_PATH or "s3a://my-bucket/raw_documents/"
    df = spark.read.parquet(input_path)

    # Assume schema: (doc_id: string, raw_text: string, source: string)
    # 1. Clean text (basic UDF example)
    @udf(StringType())
    def clean_text(text):
        if not text:
            return ""
        # Basic cleaning: strip, collapse whitespace
        return " ".join(str(text).split())

    df_clean = df.withColumn("cleaned_text", clean_text(col("raw_text")))

    # 2. Chunking UDF -> array of chunks
    chunk_schema = ArrayType(StringType())

    @udf(chunk_schema)
    def chunk_udf(text):
        return chunk_text(text, config.CHUNK_SIZE, config.CHUNK_OVERLAP)

    df_chunks = (
        df_clean
        .withColumn("chunks", chunk_udf(col("cleaned_text")))
        .select("doc_id", "source", explode("chunks").alias("chunk_text"))
        .withColumn("chunk_id", monotonically_increasing_id())
    )

    # Optional: repartition after explode if chunk count explodes
    df_chunks = df_chunks.repartition(200)

    # 3. Generate embeddings via vLLM
    # Collect chunks per partition to batch requests
    def process_partition(rows):
        texts = []
        metadata = []
        for row in rows:
            texts.append(row.chunk_text)
            metadata.append({
                "doc_id": row.doc_id,
                "chunk_id": row.chunk_id,
                "chunk_text": row.chunk_text,
                "source": row.source
            })

        embeddings = get_embeddings(texts)

        for meta, emb in zip(metadata, embeddings):
            meta["embedding"] = emb
            yield meta

    # Convert to RDD, mapPartitions for batching, then back to DataFrame
    embedding_schema = StructType([
        StructField("doc_id", StringType(), True),
        StructField("chunk_id", StringType(), True),
        StructField("chunk_text", StringType(), True),
        StructField("source", StringType(), True),
        StructField("embedding", ArrayType(FloatType()), True)
    ])

    rdd = df_chunks.rdd.mapPartitions(process_partition)
    df_embeddings = spark.createDataFrame(rdd, embedding_schema)

    # 4. Write to vector DB or S3 for later loading
    # Option A: Write to S3 as Parquet (then load into Weaviate/Milvus)
    output_path = config.S3_OUTPUT_PATH or "s3a://my-bucket/embeddings/"
    df_embeddings.write.mode("overwrite").parquet(output_path)

    # Option B: Direct insert into Weaviate (requires weaviate-client on all nodes)
    # from weaviate import Client
    # client = Client(f"http://{config.VECTOR_DB_HOST}:{config.VECTOR_DB_PORT}")
    # ... batch insert logic ...

    print(f"Pipeline complete. Embeddings written to {output_path}")
    spark.stop()


if __name__ == "__main__":
    main()
