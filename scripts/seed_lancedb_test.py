"""
Script de seed para criar a tabela LanceDB no S3 com dados de exemplo.
Não precisa de Spark nem GPU - roda localmente com CPU para testar o fluxo.
"""
import lancedb
import pyarrow as pa
from sentence_transformers import SentenceTransformer

LANCEDB_URI = "s3://vllm-chunking/lancedb"
TABLE_NAME  = "chunks"
MODEL_NAME  = "BAAI/bge-small-en-v1.5"

def get_aws_storage_options():
    """Get AWS credentials from boto3 (works with SSO, env vars, or ~/.aws/credentials)"""
    import boto3
    session  = boto3.Session()
    creds    = session.get_credentials().get_frozen_credentials()
    opts = {
        "aws_access_key_id":     creds.access_key,
        "aws_secret_access_key": creds.secret_key,
        "aws_region":            session.region_name or "us-east-1",
    }
    if creds.token:
        opts["aws_session_token"] = creds.token
    return opts

SAMPLE_CHUNKS = [
    {
        "doc_id":     "cord19-001",
        "chunk_id":   "cord19-001-0",
        "chunk_text": "COVID-19 is caused by SARS-CoV-2, a novel coronavirus first identified in Wuhan, China in late 2019. The virus spreads primarily through respiratory droplets.",
        "source":     "cord19",
    },
    {
        "doc_id":     "cord19-002",
        "chunk_id":   "cord19-002-0",
        "chunk_text": "mRNA vaccines against COVID-19, such as those developed by Pfizer-BioNTech and Moderna, showed high efficacy in clinical trials with over 90% protection against severe disease.",
        "source":     "cord19",
    },
    {
        "doc_id":     "cord19-003",
        "chunk_id":   "cord19-003-0",
        "chunk_text": "Long COVID, also known as post-acute sequelae of SARS-CoV-2 infection (PASC), affects a significant proportion of COVID-19 survivors, with symptoms including fatigue, brain fog, and shortness of breath persisting for months.",
        "source":     "cord19",
    },
    {
        "doc_id":     "cord19-004",
        "chunk_id":   "cord19-004-0",
        "chunk_text": "Remdesivir was one of the first antiviral drugs authorized for emergency use against COVID-19. It works by inhibiting the RNA-dependent RNA polymerase of SARS-CoV-2.",
        "source":     "cord19",
    },
    {
        "doc_id":     "cord19-005",
        "chunk_id":   "cord19-005-0",
        "chunk_text": "The herd immunity threshold for COVID-19 was estimated at approximately 60-70% of the population needing immunity, either through vaccination or prior infection.",
        "source":     "cord19",
    },
]

def main():
    print(f"Loading embedding model: {MODEL_NAME}")
    model = SentenceTransformer(MODEL_NAME)

    print("Generating embeddings for sample chunks...")
    texts = [c["chunk_text"] for c in SAMPLE_CHUNKS]
    embeddings = model.encode(texts, convert_to_numpy=True)

    records = []
    for chunk, vec in zip(SAMPLE_CHUNKS, embeddings):
        records.append({**chunk, "vector": vec.tolist()})

    schema = pa.schema([
        pa.field("doc_id",     pa.string()),
        pa.field("chunk_id",   pa.string()),
        pa.field("chunk_text", pa.string()),
        pa.field("source",     pa.string()),
        pa.field("vector",     pa.list_(pa.float32(), 384)),
    ])

    print(f"Connecting to LanceDB at {LANCEDB_URI}")
    storage_options = get_aws_storage_options()
    db = lancedb.connect(LANCEDB_URI, storage_options=storage_options)

    print(f"Creating table '{TABLE_NAME}' with {len(records)} records...")
    table = db.create_table(TABLE_NAME, data=records, schema=schema, mode="overwrite")
    print(f"✅ Table '{TABLE_NAME}' created successfully with {table.count_rows()} rows.")
    print("You can now test the chat at http://localhost:3000!")

if __name__ == "__main__":
    main()
