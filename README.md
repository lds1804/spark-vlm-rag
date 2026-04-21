# Project Plan: RAG with Apache Spark + vLLM on AWS

## Architecture Overview

```
[S3 Data Lake / RDS / DynamoDB]
         |
         v
[Apache Spark (EMR or EC2)]  -- Batch/Streaming ETL + Embedding Generation
         |                           (calls vLLM Embedding API)
         v
[Vector Database (Weaviate/Milvus on EC2 or Amazon OpenSearch)]
         ^
         |                           (similarity search)
    [vLLM Server (EC2 GPU)]  -- Generates embeddings + LLM answers
         ^
         |
    [API Gateway / Load Balancer]
         ^
         |
    [Client / Application]
```

## Main Components

### 1. Data Source
- Data hosted on S3 (Data Lake), RDS PostgreSQL, or DynamoDB.
- Spark reads raw data, applies transformations (cleaning, chunking), and prepares for embedding.

### 2. Apache Spark (Processing)
- **Option A: AWS EMR** (recommended for production) — managed cluster with Spark.
- **Option B: Manual EC2** — standalone Spark cluster on EC2 instances.
- Responsibilities:
  - Data ingestion and transformation.
  - **Distributed and performant chunking** via Spark (see dedicated section below).
  - Parallel calls to the vLLM embedding endpoint.
  - Writing vectors + metadata to the vector database.

### 3. Self-Hosted vLLM (EC2 GPU)
- EC2 instance with GPU (e.g., g5.xlarge, p3.2xlarge).
- vLLM serving two endpoints:
  - `/v1/embeddings` — to generate vectors for chunks in the Spark pipeline.
  - `/v1/completions` or `/v1/chat/completions` — to generate RAG answers.
- Recommended embedding model: `BAAI/bge-large-en` (or similar vLLM-compatible).
- Recommended generation model: `meta-llama/Llama-2-7b-chat-hf`, `Mistral-7B-Instruct`, etc.

### 4. Vector Database
Popular and well-supported options:
- **Weaviate** (recommended) — open-source, native vector DB, easy Docker deploy on EC2 or EKS.
- **Milvus** — highly scalable, ideal for large volumes.
- **pgvector (PostgreSQL)** — if you already use RDS PostgreSQL, the simplest option.
- **Amazon OpenSearch Serverless** — fully AWS-managed, no server to maintain.

### 5. API / Interface
- FastAPI or Flask running on EC2/ECS/EKS.
- Receives user question -> generates embedding via vLLM -> searches vector DB -> builds prompt with context -> generates answer via vLLM.

## Distributed Chunking with Spark (Performant)

Doing chunking directly in Spark is highly performant for large volumes because:
- Parallel processing across all cluster executors.
- No single-node memory bottleneck (unlike local processing).
- Horizontally scalable: more data = more workers.

### Chunking Strategies in Spark

1. **Fixed-size character chunking** (fastest):
   - PySpark UDF that splits text into `chunk_size` pieces with `overlap`.
   - Uses `explode()` to create one row per chunk.
   - Ideal when the document format is already clean (CSV, tables, logs).

2. **Structural delimiter chunking** (smarter):
   - Splits by paragraphs, chapters, or tags (e.g., `\n\n`, markdown headers).
   - Fallback to fixed-size chunking if the block is too large.
   - Better for converted PDFs or structured documents.

3. **Sentence-level chunking (NLTK / spaCy)**:
   - Can be done via UDF with `nltk.sent_tokenize` or `spaCy`.
   - Higher cost, but more semantic chunks.
   - Recommended only if processing time is acceptable; consider pre-installing libs on EMR nodes.

### Example Spark Chunking Flow

```
DataFrame(doc_id, raw_text)
  |-- UDF: clean_text(raw_text) -> cleaned_text
  |-- UDF: chunk_text(cleaned_text, chunk_size=512, overlap=50) -> List[chunk]
  |-- explode(chunks)
DataFrame(doc_id, chunk_id, chunk_text, metadata)
```

**Performance Tips**:
- Set `spark.sql.adaptive.enabled=true` to auto-optimize partitions.
- Use `repartition()` after explode if the chunk count is much larger than the document count.
- Persist (`cache()`) the post-cleanup DataFrame if it will be reused across multiple stages.

## Data Pipeline (Spark)

1. **Read**: Spark reads tables/data from S3 or relational database.
2. **Pre-processing**: text cleaning, noise removal.
3. **Distributed chunking**: splits documents into blocks via Spark UDFs (see section above).
4. **Embedding**: Spark UDF calls vLLM API in parallel batches.
5. **Write**: inserts vectors + metadata (original text, source, date) into vector DB.

## Suggested AWS Infrastructure

| Component     | AWS Service                      | Test Instance (cheap)         | Production Instance     |
|----------------|----------------------------------|-------------------------------|-------------------------|
| Spark Cluster  | EMR Serverless or EMR on EC2     | 1x m5.large (single node)     | r5.xlarge (driver), r5.2xlarge (workers) |
| vLLM Server    | EC2                              | g4dn.xlarge (cheapest GPU)    | g5.xlarge / g5.2xlarge  |
| Vector DB      | EC2 (Docker) or OpenSearch       | t3.medium (local Docker)      | r5.large / Serverless   |
| API/App        | ECS Fargate or EC2               | t3.micro                      | t3.medium               |
| Data           | S3 + RDS PostgreSQL              | -                             | -                       |

**Cost Strategy**:
- Phase 1 (test/POC): use the "Test Instance" column to validate end-to-end flow at minimum cost.
- Phase 2 (production): only upgrade to the "Production Instance" column after confirming the pipeline works.
- Use Spot Instances for the Spark cluster whenever possible (up to 70% savings).

## Project Files (suggested structure)

```
vLLM-project/
|-- README.md                    <- This plan
|-- infrastructure/
|   |-- terraform/               <- IaC for AWS (VPC, EC2, EMR, Security Groups)
|   |-- docker/
|       |-- vllm/                <- Dockerfile for vLLM server
|       |-- weaviate/            <- Docker Compose for Weaviate (if chosen)
|-- spark_jobs/
|   |-- embedding_pipeline.py    <- Main Spark job
|   |-- config.py                <- Configurations (URLs, credentials)
|-- api/
|   |-- main.py                  <- FastAPI with RAG endpoints
|   |-- rag_service.py           <- Retrieval + generation logic
|-- notebooks/
|   |-- exploration.ipynb        <- Tests and validation
```

## Next Steps

1. Choose final vector database (Weaviate recommended).
2. Create Terraform/IaC to provision VPC, EC2 GPU (vLLM), EMR, and vector DB.
3. Develop Spark embedding job and test locally.
4. Deploy vLLM on EC2 and validate embedding and chat endpoints.
5. Develop FastAPI integrating retrieval + vLLM generation.
6. End-to-end test on AWS.
