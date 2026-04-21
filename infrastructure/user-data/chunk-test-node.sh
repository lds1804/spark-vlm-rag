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

PHASE() {
    echo ""
    echo "###############################################"
    echo "###  PHASE: $1"
    echo "###  TIME:  $(date '+%Y-%m-%d %H:%M:%S')"
    echo "###############################################"
}

STEP() {
    echo "[STEP] $(date '+%H:%M:%S') $1"
}

PHASE "STARTUP"
echo "Chunk-only test started at $(date)"
echo "S3_OUTPUT_PATH=$S3_OUTPUT_PATH"
echo "Instance: $(ec2-metadata --instance-id 2>/dev/null || hostname)"

# -------------------------------------------------------
PHASE "INSTALL - System packages"
# -------------------------------------------------------
STEP "Updating apt..."
apt-get update -y -qq

STEP "Installing git, curl, wget, htop, JDK, pip, awscli..."
apt-get install -y -qq git curl wget htop openjdk-11-jdk python3-pip awscli

STEP "System packages installed."

# -------------------------------------------------------
PHASE "INSTALL - Apache Spark"
# -------------------------------------------------------
SPARK_VERSION=3.5.1
STEP "Downloading Spark ${SPARK_VERSION}..."
wget -q https://archive.apache.org/dist/spark/spark-${SPARK_VERSION}/spark-${SPARK_VERSION}-bin-hadoop3.tgz

STEP "Extracting Spark..."
tar -xzf spark-${SPARK_VERSION}-bin-hadoop3.tgz -C /opt/
ln -sfn /opt/spark-${SPARK_VERSION}-bin-hadoop3 /opt/spark

export SPARK_HOME=/opt/spark
export PATH=$PATH:$SPARK_HOME/bin:$SPARK_HOME/sbin
export PYSPARK_PYTHON=python3

STEP "Spark ${SPARK_VERSION} installed at $SPARK_HOME"

# -------------------------------------------------------
PHASE "INSTALL - Python dependencies"
# -------------------------------------------------------
STEP "Installing pyspark==${SPARK_VERSION}, pandas..."
pip3 install pyspark==${SPARK_VERSION} pandas --quiet

STEP "Python dependencies installed."

# -------------------------------------------------------
PHASE "SETUP - Clone repo"
# -------------------------------------------------------
REPO_DIR=/root/spark-vlm-rag
STEP "Cloning https://github.com/lds1804/spark-vlm-rag.git ..."
git clone https://github.com/lds1804/spark-vlm-rag.git "$REPO_DIR"

STEP "Repo cloned to $REPO_DIR"

# -------------------------------------------------------
PHASE "VALIDATE"
# -------------------------------------------------------
if [ -z "$S3_OUTPUT_PATH" ]; then
    echo "ERROR: S3_OUTPUT_PATH is not set. Exiting without shutdown so you can debug."
    exit 1
fi
STEP "S3_OUTPUT_PATH=$S3_OUTPUT_PATH"
STEP "All validations passed."

# -------------------------------------------------------
PHASE "CHUNKING - Running Spark pipeline"
# -------------------------------------------------------
cd "$REPO_DIR"
STEP "Launching spark-submit chunk_only_pipeline.py ..."
STEP "Output path: $S3_OUTPUT_PATH"
STEP "This may take several minutes depending on data volume."
echo ""

spark-submit \
    --master local[*] \
    --conf spark.sql.adaptive.enabled=true \
    spark_jobs/chunk_only_pipeline.py

EXIT_CODE=$?

# -------------------------------------------------------
PHASE "RESULT"
# -------------------------------------------------------
if [ $EXIT_CODE -eq 0 ]; then
    echo "Chunk-only test completed SUCCESSFULLY at $(date)"
    STEP "Checking S3 output..."
    aws s3 ls "${S3_OUTPUT_PATH/s3a:/s3:}" 2>/dev/null || echo "Could not list S3 output."
else
    echo "Chunk-only test FAILED with exit code $EXIT_CODE at $(date)"
fi

# -------------------------------------------------------
PHASE "SHUTDOWN"
# -------------------------------------------------------
echo "Auto-terminating instance to save costs..."
shutdown -h now
