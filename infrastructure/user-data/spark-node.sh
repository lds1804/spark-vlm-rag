#!/bin/bash
set -e

# User-data script for Spark + Weaviate + API node (t3.large / m5.large)
# This runs on first boot to set up the environment.

export HOME=/root
LOG=/var/log/spark-setup.log
exec > >(tee -a $LOG) 2>&1

echo "=== Starting Spark/Weaviate setup at $(date) ==="

# Update and install basics
apt-get update -y
apt-get install -y git curl wget htop tmux awscli openjdk-11-jdk python3-pip

# Install Docker
curl -fsSL https://get.docker.com -o get-docker.sh
sh get-docker.sh
usermod -aG docker ubuntu

# Install Docker Compose
apt-get install -y docker-compose-plugin || pip3 install docker-compose

# Install Spark 3.5
SPARK_VERSION=3.5.1
wget https://archive.apache.org/dist/spark/spark-${SPARK_VERSION}/spark-${SPARK_VERSION}-bin-hadoop3.tgz
tar -xzf spark-${SPARK_VERSION}-bin-hadoop3.tgz -C /opt/
ln -s /opt/spark-${SPARK_VERSION}-bin-hadoop3 /opt/spark

# Add Spark to system PATH
cat <<EOF > /etc/profile.d/spark.sh
export SPARK_HOME=/opt/spark
export PATH=\$PATH:\$SPARK_HOME/bin:\$SPARK_HOME/sbin
export PYSPARK_PYTHON=python3
EOF

# Install PySpark and dependencies
pip3 install pyspark==${SPARK_VERSION} pandas requests

# Clone project repo
su - ubuntu -c "git clone https://github.com/lds1804/spark-vlm-rag.git ~/spark-vlm-rag || true"

# Start Weaviate via Docker Compose (uses the compose file from the repo)
su - ubuntu -c "cd ~/spark-vlm-rag && docker compose up -d weaviate || docker-compose up -d weaviate"

echo "=== Spark/Weaviate setup complete at $(date) ==="
echo "Spark: /opt/spark/bin/spark-submit"
echo "Weaviate: http://localhost:8080"
