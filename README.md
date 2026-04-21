# Plano de Projeto: RAG com Apache Spark + vLLM na AWS

## Visao Geral da Arquitetura

```
[S3 Data Lake / RDS / DynamoDB]
         |
         v
[Apache Spark (EMR ou EC2)]  -- Batch/Streaming ETL + Embedding Generation
         |                           (chama vLLM Embedding API)
         v
[Vector Database (Weaviate/Milvus em EC2 ou Amazon OpenSearch)]
         ^
         |                           (similarity search)
    [vLLM Server (EC2 GPU)]  -- Gera embeddings + respostas LLM
         ^
         |
    [API Gateway / Load Balancer]
         ^
         |
    [Cliente / Aplicacao]
```

## Componentes Principais

### 1. Fonte de Dados
- Dados hospedados em S3 (Data Lake), RDS PostgreSQL, ou DynamoDB.
- Spark le os dados brutos, aplica transformacoes (limpeza, chunking), e prepara para embedding.

### 2. Apache Spark (Processamento)
- **Opcao A: AWS EMR** (recomendado para producao) — cluster gerenciado com Spark.
- **Opcao B: EC2 manual** — cluster Spark standalone em instancias EC2.
- Responsabilidades:
  - Ingestao e transformacao de dados.
  - **Chunking distribuido e performatico** via Spark (ver secao dedicada abaixo).
  - Chamadas paralelas ao endpoint de embeddings do vLLM.
  - Escrita dos vetores + metadados no banco vetorial.

### 3. vLLM Self-Hosted (EC2 GPU)
- Instancia EC2 com GPU (ex: g5.xlarge, p3.2xlarge).
- vLLM servindo dois endpoints:
  - `/v1/embeddings` — para gerar vetores dos chunks no pipeline Spark.
  - `/v1/completions` ou `/v1/chat/completions` — para gerar respostas RAG.
- Modelo de embedding recomendado: `BAAI/bge-large-en` (ou similar compativel com vLLM).
- Modelo de geracao recomendado: `meta-llama/Llama-2-7b-chat-hf`, `Mistral-7B-Instruct`, etc.

### 4. Vector Database
Opcoes populares e bem suportadas:
- **Weaviate** (recomendado) — open-source, nativo vetorial, facil deploy via Docker em EC2 ou EKS.
- **Milvus** — altamente escalavel, ideal para grandes volumes.
- **pgvector (PostgreSQL)** — se ja usar RDS PostgreSQL, e a opcao mais simples.
- **Amazon OpenSearch Serverless** — totalmente gerenciado pela AWS, sem servidor para manter.

### 5. API / Interface
- FastAPI ou Flask rodando em EC2/ECS/EKS.
- Recebe pergunta do usuario -> gera embedding via vLLM -> busca no vector DB -> monta prompt com contexto -> gera resposta via vLLM.

## Chunking Distribuido com Spark (Performatico)

Fazer chunking diretamente no Spark e altamente performatico para grandes volumes porque:
- Processamento paralelo em todos os executors do cluster.
- Sem gargalo de memoria de um unico no (diferente de processamento local).
- Escalavel horizontalmente: mais dados = mais workers.

### Estrategias de Chunking no Spark

1. **Chunking por caractere/tamanho fixo** (mais rapido):
   - UDF PySpark que divide texto em pedacos de `chunk_size` com `overlap`.
   - Usa `explode()` para criar uma linha por chunk.
   - Ideal quando o formato do documento ja e limpo (CSV, tabelas, logs).

2. **Chunking por delimitador estrutural** (mais inteligente):
   - Divide por paragrafos, capitulos, ou tags (ex: `\n\n`, markdown headers).
   - Fallback para chunking fixo se o bloco for muito grande.
   - Melhor para PDFs convertidos ou documentos estruturados.

3. **Chunking por sentenca (NLTK / spaCy)**:
   - Pode ser feito via UDF com `nltk.sent_tokenize` ou `spaCy`.
   - Custo maior, mas chunks mais semanticos.
   - Recomendado apenas se o tempo de processamento for aceitavel; considere pre-instalar as libs nos nodes do EMR.

### Exemplo de fluxo Spark para Chunking

```
DataFrame(doc_id, raw_text)
  |-- UDF: clean_text(raw_text) -> cleaned_text
  |-- UDF: chunk_text(cleaned_text, chunk_size=512, overlap=50) -> List[chunk]
  |-- explode(chunks)
DataFrame(doc_id, chunk_id, chunk_text, metadata)
```

**Dica de performance**:
- Ajuste `spark.sql.adaptive.enabled=true` para otimizar particoes automaticamente.
- Use `repartition()` apos o explode se o numero de chunks for muito maior que o de documentos.
- Persista (`cache()`) o DataFrame pos-limpeza se ele for reusado em multiplas etapas.

## Pipeline de Dados (Spark)

1. **Leitura**: Spark le tabelas/dados do S3 ou banco relacional.
2. **Pre-processamento**: limpeza de texto, remocao de ruido.
3. **Chunking distribuido**: divide documentos em blocos via Spark UDFs (ver secao acima).
4. **Embedding**: UDF Spark chama API do vLLM em batches paralelos.
5. **Escrita**: Insere vetores + metadados (texto original, fonte, data) no vector DB.

## Infraestrutura AWS Sugerida

| Componente     | Servico AWS                      | Instancia para Teste (barata) | Instancia para Producao |
|----------------|----------------------------------|-------------------------------|-------------------------|
| Spark Cluster  | EMR Serverless ou EMR on EC2     | 1x m5.large (single node)     | r5.xlarge (driver), r5.2xlarge (workers) |
| vLLM Server    | EC2                              | g4dn.xlarge (GPU mais barata) | g5.xlarge / g5.2xlarge  |
| Vector DB      | EC2 (Docker) ou OpenSearch       | t3.medium (Docker local)      | r5.large / Serverless   |
| API/App        | ECS Fargate ou EC2               | t3.micro                      | t3.medium               |
| Dados          | S3 + RDS PostgreSQL              | -                             | -                       |

**Estrategia de custo**:
- Fase 1 (teste/POC): use a coluna "Instancia para Teste" para validar o fluxo end-to-end com custo minimo.
- Fase 2 (producao): substitua pelas instancias da coluna "Producao" apenas apos confirmar que o pipeline funciona.
- Use Spot Instances para o Spark cluster sempre que possivel (economia de ate 70%).

## Arquivos do Projeto (estrutura sugerida)

```
vLLM-project/
|-- README.md                    <- Este plano
|-- infrastructure/
|   |-- terraform/               <- IaC para AWS (VPC, EC2, EMR, Security Groups)
|   |-- docker/
|       |-- vllm/                <- Dockerfile para servidor vLLM
|       |-- weaviate/            <- Docker Compose para Weaviate (se escolhido)
|-- spark_jobs/
|   |-- embedding_pipeline.py    <- Job Spark principal
|   |-- config.py                <- Configuracoes (URLs, credenciais)
|-- api/
|   |-- main.py                  <- FastAPI com endpoints RAG
|   |-- rag_service.py           <- Logica de retrieval + generation
|-- notebooks/
|   |-- exploracao.ipynb         <- Testes e validacao
```

## Proximos Passos

1. Escolher vector database definitivo (Weaviate recomendado).
2. Criar Terraform/IaC para provisionar VPC, EC2 GPU (vLLM), EMR, e vector DB.
3. Desenvolver job Spark de embedding e testar localmente.
4. Subir vLLM em EC2 e validar endpoints de embedding e chat.
5. Desenvolver API FastAPI integrando retrieval + vLLM generation.
6. Teste end-to-end na AWS.
