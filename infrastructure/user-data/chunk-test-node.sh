#!/bin/bash
set -e

# User-data script for a ONE-OFF chunking test.
# Installs Spark, runs chunk_only_pipeline.py on CORD-19, writes to S3,
# then shuts down the instance automatically.
#
# Environment variables (set via --user-data or cloud-init):
#   S3_OUTPUT_PATH   - where to write chunks (required)
#   CHUNK_SIZE       - optional, default 512
#   CHUNK_OVERLAP    - optional, default 50

export HOME=/root
LOG=/var/log/chunk-test.log
exec > >(tee -a $LOG) 2>&1

echo "=== Chunk-only test started at $(date) ==="

# Update and install basics
apt-get update -y
apt-get install -y git curl wget htop openjdk-11-jdk python3-pip awscli

# Install Spark 3.5
SPARK_VERSION=3.5.1
wget -q https://archive.apache.org/dist/spark/spark-${SPARK_VERSION}/spark-${SPARK_VERSION}-bin-hadoop3.tgz
tar -xzf spark-${SPARK_VERSION}-bin-hadoop3.tgz -C /opt/
ln -s /opt/spark-${SPARK_VERSION}-bin-hadoop3 /opt/spark

export SPARK_HOME=/opt/spark
export PATH=$PATH:$SPARK_HOME/bin:$SPARK_HOME/sbin
export PYSPARK_PYTHON=python3

# Install PySpark + dependencies
pip3 install pyspark==${SPARK_VERSION} pandas --quiet

# Clone project repo
REPO_DIR=/root/spark-vlm-rag
git clone https://github.com/lds1804/spark-vlm-rag.git "$REPO_DIR"

# Ensure output path is set
if [ -z "$S3_OUTPUT_PATH" ]; then
    echo "ERROR: S3_OUTPUT_PATH is not set. Exiting without shutdown so you can debug."
    exit 1
fi

# Run the chunk-only pipeline
cd "$REPO_DIR"
echo "Running chunk_only_pipeline.py with output=$S3_OUTPUT_PATH"
spark-submit \
    --master local[*] \
    --conf spark.sql.adaptive.enabled=true \
    spark_jobs/chunk_only_pipeline.py

EXIT_CODE=$?
if [ $EXIT_CODE -eq 0 ]; then
    echo "=== Chunk-only test completed successfully at $(date) ==="
else
    echo "=== Chunk-only test FAILED with exit code $EXIT_CODE at $(date) ==="
fi

# Auto-terminate instance regardless of success/failure (saves money)
echo "Shutting down instance..."
shutdown -h now
