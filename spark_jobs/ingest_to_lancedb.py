"""
Spark job for distributed embedding generation and storage in LanceDB on S3.

Usage:
    spark-submit --master local[*] spark_jobs/ingest_to_lancedb.py
"""

import os
import pandas as pd
import pyarrow as pa
import lancedb
from typing import Iterator
from pyspark.sql import SparkSession
from pyspark.sql.functions import col
from pyspark.sql.types import ArrayType, FloatType, StringType, StructType, StructField
from sentence_transformers import SentenceTransformer

import config

def get_spark_session():
    return (
        SparkSession.builder
        .appName("LanceDB-Local-CPU-Ingestion")
        .config("spark.sql.execution.arrow.pyspark.enabled", "true")
        .config("spark.hadoop.fs.s3a.connection.timeout", "60000")
        .config("spark.hadoop.fs.s3a.connection.establish.timeout", "60000")
        .config("spark.hadoop.fs.s3a.impl", "org.apache.hadoop.fs.s3a.S3AFileSystem")
        .getOrCreate()
    )

def main():
    spark = get_spark_session()
    
    import sys
    input_path = sys.argv[1] if len(sys.argv) > 1 else (config.S3_INPUT_PATH or "s3a://vllm-chunking/cord19-chunks/")
    db_uri = sys.argv[2] if len(sys.argv) > 2 else config.LANCEDB_URI
    
    print(f"Reading existing chunks from: {input_path}")
    df = spark.read.parquet(input_path)
    
    # Limit to 5000 rows to expand the knowledge base using CPU
    print("WARNING: AWS GPU Limit reached. Running on local CPU with a limit of 5000 chunks.")
    df = df.limit(5000)
    
    # 2. Define the schema for the output
    schema = StructType([
        StructField("doc_id", StringType(), True),
        StructField("chunk_id", StringType(), True),
        StructField("chunk_text", StringType(), True),
        StructField("source", StringType(), True),
        StructField("vector", ArrayType(FloatType()), True),
    ])

    embedding_model_name = config.EMBEDDING_MODEL or "BAAI/bge-small-en-v1.5"

    def embed_batch(iterator: Iterator[pd.DataFrame]) -> Iterator[pd.DataFrame]:
        model = SentenceTransformer(embedding_model_name)
        for pdf in iterator:
            texts = pdf["chunk_text"].tolist()
            embeddings = model.encode(texts, convert_to_numpy=True)
            pdf["vector"] = embeddings.tolist()
            yield pdf

    print("Starting local CPU embedding generation...")
    df_with_vectors = df.mapInPandas(embed_batch, schema=schema)

    
    # 3. Write to LanceDB on S3
    table_name = config.LANCEDB_TABLE_NAME
    
    def write_to_lancedb(pdf: pd.DataFrame):
        db = lancedb.connect(db_uri)
        if table_name in db.table_names():
            table = db.open_table(table_name)
            table.add(pdf)
        else:
            db.create_table(table_name, data=pdf)
            
    print(f"Saving to LanceDB at: {db_uri}")
    df_with_vectors.foreachPartition(write_to_lancedb)
    
    print("Ingestion complete.")
    spark.stop()

if __name__ == "__main__":
    main()
