#!/bin/bash
set -e

# =============================================================================
# AWS POC Launcher — Small instances for testing the RAG pipeline
# =============================================================================
# This script spins up:
#   1. A GPU instance (g4dn.xlarge) running vLLM
#   2. A CPU instance (t3.large) running Spark + Weaviate
#
# Requirements:
#   - AWS CLI installed and configured (aws configure)
#   - An existing EC2 Key Pair (or let the script create one)
#   - Default VPC available in your chosen region
#
# Cost estimate (us-east-1, on-demand):
#   g4dn.xlarge ~ $0.526/hr  (vLLM)
#   t3.large    ~ $0.083/hr  (Spark + Weaviate)
#   Total       ~ $0.61/hr
#
# Usage:
#   export AWS_REGION=us-east-1
#   export KEY_NAME=my-key
#   ./aws-poc-launch.sh
# =============================================================================

AWS_REGION=${AWS_REGION:-us-east-1}
KEY_NAME=${KEY_NAME:-""}
PROJECT_TAG="spark-vlm-rag-poc"

# ---------------------------------------------------------------------------
# Colors for output
# ---------------------------------------------------------------------------
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

info()  { echo -e "${GREEN}[INFO]${NC} $1"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $1"; }
error() { echo -e "${RED}[ERROR]${NC} $1"; exit 1; }

# ---------------------------------------------------------------------------
# Validate prerequisites
# ---------------------------------------------------------------------------
command -v aws >/dev/null 2>&1 || error "AWS CLI not found. Install it first: https://docs.aws.amazon.com/cli/"

aws sts get-caller-identity >/dev/null 2>&1 || error "AWS CLI not authenticated. Run: aws configure"

# ---------------------------------------------------------------------------
# Key Pair handling
# ---------------------------------------------------------------------------
if [ -z "$KEY_NAME" ]; then
    warn "KEY_NAME not set."
    read -rp "Enter your existing EC2 Key Pair name (or press Enter to create 'poc-key'): " KEY_NAME
    KEY_NAME=${KEY_NAME:-poc-key}
fi

KEY_EXISTS=$(aws ec2 describe-key-pairs --region "$AWS_REGION" --key-names "$KEY_NAME" --query 'KeyPairs[0].KeyName' --output text 2>/dev/null || echo "none")

if [ "$KEY_EXISTS" == "none" ]; then
    info "Creating new key pair: $KEY_NAME"
    aws ec2 create-key-pair \
        --region "$AWS_REGION" \
        --key-name "$KEY_NAME" \
        --query 'KeyMaterial' \
        --output text > "${KEY_NAME}.pem"
    chmod 400 "${KEY_NAME}.pem"
    info "Private key saved to ${KEY_NAME}.pem"
else
    info "Using existing key pair: $KEY_NAME"
    if [ ! -f "${KEY_NAME}.pem" ]; then
        warn "Key file ${KEY_NAME}.pem not found locally. Make sure you have it to SSH into instances."
    fi
fi

# ---------------------------------------------------------------------------
# Get default VPC and subnet
# ---------------------------------------------------------------------------
info "Detecting default VPC in $AWS_REGION..."
VPC_ID=$(aws ec2 describe-vpcs \
    --region "$AWS_REGION" \
    --filters Name=isDefault,Values=true \
    --query 'Vpcs[0].VpcId' \
    --output text)

[ "$VPC_ID" == "None" ] && error "No default VPC found in $AWS_REGION. Please create one or specify a VPC ID."
info "Default VPC: $VPC_ID"

SUBNET_ID=$(aws ec2 describe-subnets \
    --region "$AWS_REGION" \
    --filters Name=vpc-id,Values="$VPC_ID" Name=default-for-az,Values=true \
    --query 'Subnets[0].SubnetId' \
    --output text)

info "Default Subnet: $SUBNET_ID"

# ---------------------------------------------------------------------------
# Create Security Group
# ---------------------------------------------------------------------------
info "Creating security group..."
SG_NAME="${PROJECT_TAG}-sg"

# Check if SG already exists
SG_ID=$(aws ec2 describe-security-groups \
    --region "$AWS_REGION" \
    --filters Name=group-name,Values="$SG_NAME" Name=vpc-id,Values="$VPC_ID" \
    --query 'SecurityGroups[0].GroupId' \
    --output text 2>/dev/null || echo "none")

if [ "$SG_ID" == "none" ]; then
    SG_ID=$(aws ec2 create-security-group \
        --region "$AWS_REGION" \
        --group-name "$SG_NAME" \
        --description "Security group for spark-vlm-rag POC" \
        --vpc-id "$VPC_ID" \
        --query 'GroupId' \
        --output text)
    info "Created security group: $SG_ID"

    # Allow SSH from anywhere (restrict to your IP in production!)
    aws ec2 authorize-security-group-ingress \
        --region "$AWS_REGION" \
        --group-id "$SG_ID" \
        --protocol tcp --port 22 --cidr 0.0.0.0/0 >/dev/null

    # Allow internal traffic between POC instances
    aws ec2 authorize-security-group-ingress \
        --region "$AWS_REGION" \
        --group-id "$SG_ID" \
        --protocol all --source-group "$SG_ID" >/dev/null

    # Allow vLLM API (port 8000) from anywhere
    aws ec2 authorize-security-group-ingress \
        --region "$AWS_REGION" \
        --group-id "$SG_ID" \
        --protocol tcp --port 8000 --cidr 0.0.0.0/0 >/dev/null

    # Allow Weaviate (port 8080) from anywhere
    aws ec2 authorize-security-group-ingress \
        --region "$AWS_REGION" \
        --group-id "$SG_ID" \
        --protocol tcp --port 8080 --cidr 0.0.0.0/0 >/dev/null

    # Allow FastAPI (port 8001) from anywhere
    aws ec2 authorize-security-group-ingress \
        --region "$AWS_REGION" \
        --group-id "$SG_ID" \
        --protocol tcp --port 8001 --cidr 0.0.0.0/0 >/dev/null
else
    info "Using existing security group: $SG_ID"
fi

# ---------------------------------------------------------------------------
# Launch Instances
# ---------------------------------------------------------------------------
info "Launching instances..."

USER_DATA_DIR="$(dirname "$0")/user-data"

# --- GPU Instance (vLLM) ---
GPU_INSTANCE_TYPE=${GPU_INSTANCE_TYPE:-g4dn.xlarge}
GPU_AMI=$(aws ec2 describe-images \
    --region "$AWS_REGION" \
    --owners 099720109477 \
    --filters Name=name,Values='ubuntu/images/hvm-ssd/ubuntu-jammy-22.04-amd64-server-*' Name=state,Values=available \
    --query 'sort_by(Images, &CreationDate)[-1].ImageId' \
    --output text)

info "GPU AMI: $GPU_AMI  Type: $GPU_INSTANCE_TYPE"

GPU_USER_DATA=$(base64 -w 0 "${USER_DATA_DIR}/vllm-gpu.sh" 2>/dev/null || base64 "${USER_DATA_DIR}/vllm-gpu.sh")

GPU_INSTANCE_ID=$(aws ec2 run-instances \
    --region "$AWS_REGION" \
    --image-id "$GPU_AMI" \
    --instance-type "$GPU_INSTANCE_TYPE" \
    --key-name "$KEY_NAME" \
    --security-group-ids "$SG_ID" \
    --subnet-id "$SUBNET_ID" \
    --user-data "$GPU_USER_DATA" \
    --block-device-mappings '[{"DeviceName":"/dev/sda1","Ebs":{"VolumeSize":100,"VolumeType":"gp3"}}]' \
    --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=${PROJECT_TAG}-vllm},{Key=Project,Value=${PROJECT_TAG}}]" \
    --query 'Instances[0].InstanceId' \
    --output text)

info "Launched GPU instance: $GPU_INSTANCE_ID"

# --- CPU Instance (Spark + Weaviate) ---
CPU_INSTANCE_TYPE=${CPU_INSTANCE_TYPE:-t3.large}
CPU_AMI=$GPU_AMI  # Same Ubuntu 22.04 AMI

CPU_USER_DATA=$(base64 -w 0 "${USER_DATA_DIR}/spark-node.sh" 2>/dev/null || base64 "${USER_DATA_DIR}/spark-node.sh")

CPU_INSTANCE_ID=$(aws ec2 run-instances \
    --region "$AWS_REGION" \
    --image-id "$CPU_AMI" \
    --instance-type "$CPU_INSTANCE_TYPE" \
    --key-name "$KEY_NAME" \
    --security-group-ids "$SG_ID" \
    --subnet-id "$SUBNET_ID" \
    --user-data "$CPU_USER_DATA" \
    --block-device-mappings '[{"DeviceName":"/dev/sda1","Ebs":{"VolumeSize":50,"VolumeType":"gp3"}}]' \
    --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=${PROJECT_TAG}-spark},{Key=Project,Value=${PROJECT_TAG}}]" \
    --query 'Instances[0].InstanceId' \
    --output text)

info "Launched CPU instance: $CPU_INSTANCE_ID"

# ---------------------------------------------------------------------------
# Wait for instances to be running
# ---------------------------------------------------------------------------
info "Waiting for instances to enter 'running' state..."
aws ec2 wait instance-running --region "$AWS_REGION" --instance-ids "$GPU_INSTANCE_ID" "$CPU_INSTANCE_ID"

# ---------------------------------------------------------------------------
# Get public IPs
# ---------------------------------------------------------------------------
sleep 5  # Allow a moment for public IPs to be assigned

GPU_IP=$(aws ec2 describe-instances \
    --region "$AWS_REGION" \
    --instance-ids "$GPU_INSTANCE_ID" \
    --query 'Reservations[0].Instances[0].PublicIpAddress' \
    --output text)

CPU_IP=$(aws ec2 describe-instances \
    --region "$AWS_REGION" \
    --instance-ids "$CPU_INSTANCE_ID" \
    --query 'Reservations[0].Instances[0].PublicIpAddress' \
    --output text)

# ---------------------------------------------------------------------------
# Output summary
# ---------------------------------------------------------------------------
echo ""
echo "============================================================================="
echo "                         POC INSTANCES READY"
echo "============================================================================="
echo ""
echo "  vLLM GPU Instance"
echo "    ID:   $GPU_INSTANCE_ID"
echo "    IP:   $GPU_IP"
echo "    SSH:  ssh -i ${KEY_NAME}.pem ubuntu@$GPU_IP"
echo "    API:  http://$GPU_IP:8000"
echo ""
echo "  Spark + Weaviate Instance"
echo "    ID:   $CPU_INSTANCE_ID"
echo "    IP:   $CPU_IP"
echo "    SSH:  ssh -i ${KEY_NAME}.pem ubuntu@$CPU_IP"
echo "    Weaviate: http://$CPU_IP:8080"
echo ""
echo "============================================================================="
echo "                         NEXT STEPS"
echo "============================================================================="
echo ""
echo "1. Wait ~5-10 minutes for user-data scripts to finish (model download + setup)."
echo "   Check progress: ssh into each box and run 'tail -f /var/log/*.log'"
echo ""
echo "2. On the Spark node, set the vLLM host and run the pipeline:"
echo "   ssh -i ${KEY_NAME}.pem ubuntu@$CPU_IP"
echo "   export VLLM_HOST=http://$GPU_IP:8000"
echo "   export S3_OUTPUT_PATH=s3a://YOUR-BUCKET/cord19-embeddings/"
echo "   cd ~/spark-vlm-rag"
echo "   spark-submit --master local[*] spark_jobs/cord19_pipeline.py"
echo ""
echo "3. To save money, STOP (not terminate) instances when not in use:"
echo "   aws ec2 stop-instances --region $AWS_REGION --instance-ids $GPU_INSTANCE_ID $CPU_INSTANCE_ID"
echo ""
echo "4. To destroy everything when done:"
echo "   aws ec2 terminate-instances --region $AWS_REGION --instance-ids $GPU_INSTANCE_ID $CPU_INSTANCE_ID"
echo "   aws ec2 delete-security-group --region $AWS_REGION --group-id $SG_ID"
echo ""
echo "============================================================================="

# Save details to a file for later reference
cat > "poc-instances-${PROJECT_TAG}.txt" <<EOF
GPU_INSTANCE_ID=$GPU_INSTANCE_ID
GPU_IP=$GPU_IP
CPU_INSTANCE_ID=$CPU_INSTANCE_ID
CPU_IP=$CPU_IP
SG_ID=$SG_ID
KEY_NAME=$KEY_NAME
REGION=$AWS_REGION
EOF

info "Details saved to: poc-instances-${PROJECT_TAG}.txt"
