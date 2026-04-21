"""
Spark job that ONLY performs chunking on CORD-19 (no embeddings, no vLLM).

Use this to test the distributed chunking stage in isolation.
Output: Parquet files with one row per chunk on S3.

Usage:
    export S3_OUTPUT_PATH=s3a://my-bucket/cord19-chunks/
    spark-submit --master local[*] spark_jobs/chunk_only_pipeline.py
"""

import os
from typing import List
import pandas as pd
from pyspark.sql import SparkSession
from pyspark.sql.functions import (
    explode, col, monotonically_increasing_id,
    concat_ws, regexp_replace, trim, pandas_udf,
)
from pyspark.sql.types import ArrayType, StringType

import config

CORD19_S3_PATH = "s3a://ai2-semanticscholar-cord-19/2024-11-26/metadata/"


def chunk_text(text: str, chunk_size: int = config.CHUNK_SIZE, overlap: int = config.CHUNK_OVERLAP) -> List[str]:
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


def main():
    spark = (
        SparkSession.builder
        .appName("CORD19-ChunkOnly")
        .master(config.SPARK_MASTER)
        .config("spark.sql.adaptive.enabled", "true")
        .config("spark.sql.adaptive.coalescePartitions.enabled", "true")
        .getOrCreate()
    )

    # 1. Read CORD-19 metadata from public S3 (CSV, no schema inference)
    df = (
        spark.read
        .option("header", True)
        .option("inferSchema", False)
        .csv(CORD19_S3_PATH + "*.csv")
    )

    # 2. Build raw text from title + abstract
    df_text = (
        df.select("cord_uid", "title", "abstract")
        .withColumn("raw_text", concat_ws("\n\n", col("title"), col("abstract")))
        .filter(col("raw_text").isNotNull())
    )

    # 3. Native Spark text cleaning
    df_clean = df_text.withColumn(
        "cleaned_text",
        trim(regexp_replace(col("raw_text"), r"\s+", " ")),
    )

    # 4. Vectorised chunking via pandas UDF
    @pandas_udf(ArrayType(StringType()))
    def chunk_udf(texts: pd.Series) -> pd.Series:
        return texts.apply(lambda t: chunk_text(t, config.CHUNK_SIZE, config.CHUNK_OVERLAP))

    df_chunks = (
        df_clean
        .withColumn("chunks", chunk_udf(col("cleaned_text")))
        .select("cord_uid", "title", explode("chunks").alias("chunk_text"))
        .withColumn("chunk_id", monotonically_increasing_id())
    )

    # 5. Write chunks to S3
    output_path = config.S3_OUTPUT_PATH or "s3a://my-bucket/cord19-chunks/"
    df_chunks.write.mode("overwrite").parquet(output_path)

    total_chunks = df_chunks.count()
    print(f"Chunk-only pipeline complete. {total_chunks} chunks written to {output_path}")
    spark.stop()


if __name__ == "__main__":
    main()
