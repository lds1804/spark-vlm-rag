"""
Spark job for ingesting CORD-19 from S3, chunking papers, and generating embeddings.

CORD-19 structure (metadata):
  s3://ai2-semanticscholar-cord-19/YYYY-MM-DD/metadata/
    - csv files with columns: cord_uid, title, abstract, authors, ...

Full-text is available via PMC JSON parses in separate sub-folders.
For a quick test we use the 'abstract' column; swap to body_text for full articles.

Usage:
    export VLLM_HOST=http://localhost:8000
    export S3_OUTPUT_PATH=s3a://my-bucket/cord19-embeddings/
    spark-submit --master local[*] spark_jobs/cord19_pipeline.py
"""

import requests
from typing import List
from pyspark.sql import SparkSession
from pyspark.sql.functions import udf, explode, col, monotonically_increasing_id
from pyspark.sql.types import ArrayType, StringType, StructType, StructField, FloatType

import config

# CORD-19 public S3 bucket (us-west-2)
CORD19_S3_PATH = "s3a://ai2-semanticscholar-cord-19/2024-11-26/metadata/"


def chunk_text(text: str, chunk_size: int = config.CHUNK_SIZE, overlap: int = config.CHUNK_OVERLAP) -> List[str]:
    """Fixed-size character chunking with overlap."""
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
    """Call vLLM embedding endpoint in batches."""
    if not texts:
        return []

    headers = {"Content-Type": "application/json"}
    if config.VLLM_API_KEY:
        headers["Authorization"] = f"Bearer {config.VLLM_API_KEY}"

    embeddings = []
    batch_size = config.EMBEDDING_BATCH_SIZE

    for i in range(0, len(texts), batch_size):
        batch = texts[i:i + batch_size]
        payload = {"model": config.EMBEDDING_MODEL, "input": batch}
        try:
            response = requests.post(
                config.VLLM_EMBEDDING_ENDPOINT,
                headers=headers,
                json=payload,
                timeout=120,
            )
            response.raise_for_status()
            data = response.json()
            batch_embeddings = [item["embedding"] for item in data["data"]]
            embeddings.extend(batch_embeddings)
        except Exception as e:
            print(f"Error fetching embeddings for batch {i}: {e}")
            zero_vec = [0.0] * 1024
            embeddings.extend([zero_vec] * len(batch))

    return embeddings


def main():
    spark = (
        SparkSession.builder
        .appName("CORD19-RAG-Pipeline")
        .master(config.SPARK_MASTER)
        .config("spark.sql.adaptive.enabled", "true")
        .config("spark.sql.adaptive.coalescePartitions.enabled", "true")
        .getOrCreate()
    )

    # 1. Read CORD-19 metadata from public S3
    # CORD-19 metadata files are CSVs inside a partitioned prefix.
    # Use wildcard to load all CSV parts.
    df = spark.read.option("header", True).csv(CORD19_S3_PATH + "*.csv")

    print(f"Loaded {df.count()} papers from CORD-19")

    # 2. Select relevant text columns and concatenate
    # For POC we use: title + abstract
    # In production, read full-text JSON and use body_text paragraphs.
    from pyspark.sql.functions import concat_ws

    df_text = (
        df.select("cord_uid", "title", "abstract")
        .withColumn(
            "raw_text",
            concat_ws(
                "\n\n",
                col("title"),
                col("abstract"),
            ),
        )
        .filter(col("raw_text").isNotNull())
    )

    # 3. Clean text (basic UDF)
    @udf(StringType())
    def clean_text(text):
        if not text:
            return ""
        return " ".join(str(text).split())

    df_clean = df_text.withColumn("cleaned_text", clean_text(col("raw_text")))

    # 4. Chunking UDF
    chunk_schema = ArrayType(StringType())

    @udf(chunk_schema)
    def chunk_udf(text):
        return chunk_text(text, config.CHUNK_SIZE, config.CHUNK_OVERLAP)

    df_chunks = (
        df_clean
        .withColumn("chunks", chunk_udf(col("cleaned_text")))
        .select("cord_uid", "title", explode("chunks").alias("chunk_text"))
        .withColumn("chunk_id", monotonically_increasing_id())
    )

    # Repartition after explode to balance workload
    df_chunks = df_chunks.repartition(200)

    # 5. Generate embeddings via vLLM (batched per partition)
    def process_partition(rows):
        texts = []
        metadata = []
        for row in rows:
            texts.append(row.chunk_text)
            metadata.append({
                "doc_id": row.cord_uid,
                "chunk_id": row.chunk_id,
                "chunk_text": row.chunk_text,
                "title": row.title,
            })

        embeddings = get_embeddings(texts)
        for meta, emb in zip(metadata, embeddings):
            meta["embedding"] = emb
            yield meta

    embedding_schema = StructType([
        StructField("doc_id", StringType(), True),
        StructField("chunk_id", StringType(), True),
        StructField("chunk_text", StringType(), True),
        StructField("title", StringType(), True),
        StructField("embedding", ArrayType(FloatType()), True),
    ])

    rdd = df_chunks.rdd.mapPartitions(process_partition)
    df_embeddings = spark.createDataFrame(rdd, embedding_schema)

    # 6. Write results to S3
    output_path = config.S3_OUTPUT_PATH or "s3a://my-bucket/cord19-embeddings/"
    df_embeddings.write.mode("overwrite").parquet(output_path)

    print(f"CORD-19 pipeline complete. Embeddings written to {output_path}")
    spark.stop()


if __name__ == "__main__":
    main()
