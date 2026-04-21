#!/bin/bash
set -e

# User-data script for vLLM GPU instance (g4dn.xlarge)
# This runs on first boot to set up the environment.

export HOME=/root
LOG=/var/log/vllm-setup.log
exec > >(tee -a $LOG) 2>&1

echo "=== Starting vLLM GPU setup at $(date) ==="

# Update and install basics
apt-get update -y
apt-get install -y git curl wget htop tmux awscli

# Install NVIDIA drivers (Ubuntu 22.04 / 24.04)
# For g4dn instances (T4 GPU)
apt-get install -y linux-headers-$(uname -r)
distribution=$(. /etc/os-release;echo $ID$VERSION_ID | sed -e 's/\.//g')
wget https://developer.download.nvidia.com/compute/cuda/repos/$distribution/x86_64/cuda-keyring_1.0-1_all.deb
dpkg -i cuda-keyring_1.0-1_all.deb
apt-get update -y
apt-get install -y cuda-drivers

# Install Docker
curl -fsSL https://get.docker.com -o get-docker.sh
sh get-docker.sh
usermod -aG docker ubuntu

# Install nvidia-docker2
distribution=$(. /etc/os-release;echo $ID$VERSION_ID)
curl -s -L https://nvidia.github.io/nvidia-docker/gpgkey | apt-key add -
curl -s -L https://nvidia.github.io/nvidia-docker/$distribution/nvidia-docker.list | tee /etc/apt/sources.list.d/nvidia-docker.list
apt-get update -y
apt-get install -y nvidia-docker2
systemctl restart docker

# Clone project repo (optional — adjust if you want a specific branch)
su - ubuntu -c "git clone https://github.com/lds1804/spark-vlm-rag.git ~/spark-vlm-rag || true"

# Pull and run vLLM with an embedding-capable model
# Using a small model for quick testing. Swap to a larger one for production.
docker run -d --name vllm \
  --runtime nvidia \
  --gpus all \
  -p 8000:8000 \
  -v ~/.cache/huggingface:/root/.cache/huggingface \
  --restart unless-stopped \
  vllm/vllm-openai:latest \
  --model BAAI/bge-large-en \
  --dtype half \
  --max-model-len 512 \
  --tensor-parallel-size 1

echo "=== vLLM setup complete at $(date) ==="
echo "API should be available on port 8000 after model downloads (~5-10 min)"
