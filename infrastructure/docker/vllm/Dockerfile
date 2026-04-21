# Dockerfile for vLLM server with embedding + chat capabilities
# Tested with NVIDIA GPUs (g4dn / g5 instances on AWS)

FROM vllm/vllm-openai:latest

# Arguments for model selection
ARG EMBEDDING_MODEL=BAAI/bge-large-en
ARG LLM_MODEL=mistralai/Mistral-7B-Instruct-v0.2

# Environment variables
ENV PYTHONUNBUFFERED=1
ENV CUDA_MODULE_LOADING=LAZY

# Expose vLLM OpenAI-compatible API port
EXPOSE 8000

# Default command: serve both embedding and LLM models.
# In production you may run separate containers for embedding vs generation.
#
# vLLM currently serves ONE model per process best.
# For POC/testing on a single GPU, pick the model you need most:
#   - If indexing data: use EMBEDDING_MODEL
#   - If serving queries: use LLM_MODEL
#
# For production, deploy two EC2 instances or use --pipeline-parallel-size if supported.

CMD python -m vllm.entrypoints.openai.api_server \
    --model ${LLM_MODEL} \
    --dtype half \
    --max-model-len 4096 \
    --tensor-parallel-size 1 \
    --port 8000

# NOTE: For embedding models, change --model to ${EMBEDDING_MODEL}.
# You can also run two containers on the same host with different ports
# using Docker Compose.
