#!/bin/bash
set -e

# =============================================================================
# AWS Chunking-Only Test Launcher
# =============================================================================
# Spins up a single cheap EC2 instance, runs the CORD-19 chunking pipeline,
# writes results to YOUR S3 bucket, and auto-terminates when done.
#
# This tests ONLY the Spark chunking stage — no vLLM, no embeddings,
# no Weaviate.  Fast and cheap.
#
# Cost estimate (us-east-1, Spot):
#   m5.large ~ $0.04-0.08/hr  => a few cents total
#
# Requirements:
#   - AWS CLI installed and configured
#   - An existing EC2 Key Pair (optional, mainly for debug SSH)
#   - An S3 bucket for output
#
# Usage:
#   export AWS_REGION=us-east-1
#   export S3_OUTPUT_PATH=s3a://my-bucket/cord19-chunks-test/
#   export KEY_NAME=my-key          # optional, for debug SSH
#   ./aws-test-chunking-only.sh
# =============================================================================

AWS_REGION=${AWS_REGION:-us-east-1}
KEY_NAME=${KEY_NAME:-""}
INSTANCE_TYPE=${INSTANCE_TYPE:-m5.large}
PROJECT_TAG="spark-vlm-rag-chunk-test"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

info()  { echo -e "${GREEN}[INFO]${NC} $1"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $1"; }
error() { echo -e "${RED}[ERROR]${NC} $1"; exit 1; }

# ---------------------------------------------------------------------------
# Validate prerequisites
# ---------------------------------------------------------------------------
command -v aws >/dev/null 2>&1 || error "AWS CLI not found."
aws sts get-caller-identity >/dev/null 2>&1 || error "AWS CLI not authenticated."
[ -z "$S3_OUTPUT_PATH" ] && error "S3_OUTPUT_PATH must be set (e.g., s3a://my-bucket/cord19-chunks/)"

info "Region: $AWS_REGION"
info "Output: $S3_OUTPUT_PATH"
info "Instance type: $INSTANCE_TYPE"

# ---------------------------------------------------------------------------
# Get default VPC + subnet
# ---------------------------------------------------------------------------
VPC_ID=$(aws ec2 describe-vpcs --region "$AWS_REGION" --filters Name=isDefault,Values=true --query 'Vpcs[0].VpcId' --output text)
[ "$VPC_ID" == "None" ] && error "No default VPC found."
SUBNET_ID=$(aws ec2 describe-subnets --region "$AWS_REGION" --filters Name=vpc-id,Values="$VPC_ID" Name=default-for-az,Values=true --query 'Subnets[0].SubnetId' --output text)

# ---------------------------------------------------------------------------
# Security group (allow SSH for debug; open egress for S3 access)
# ---------------------------------------------------------------------------
SG_NAME="${PROJECT_TAG}-sg"
SG_ID=$(aws ec2 describe-security-groups --region "$AWS_REGION" --filters Name=group-name,Values="$SG_NAME" Name=vpc-id,Values="$VPC_ID" --query 'SecurityGroups[0].GroupId' --output text 2>/dev/null || echo "none")

if [ "$SG_ID" == "none" ]; then
    SG_ID=$(aws ec2 create-security-group --region "$AWS_REGION" --group-name "$SG_NAME" --description "SG for chunking test" --vpc-id "$VPC_ID" --query 'GroupId' --output text)
    aws ec2 authorize-security-group-ingress --region "$AWS_REGION" --group-id "$SG_ID" --protocol tcp --port 22 --cidr 0.0.0.0/0 >/dev/null
    aws ec2 authorize-security-group-egress  --region "$AWS_REGION" --group-id "$SG_ID" --protocol all --cidr 0.0.0.0/0 >/dev/null || true
    info "Created security group: $SG_ID"
else
    info "Using existing security group: $SG_ID"
fi

# ---------------------------------------------------------------------------
# Build user-data with S3_OUTPUT_PATH baked in
# ---------------------------------------------------------------------------
USER_DATA_DIR="$(dirname "$0")/user-data"
RAW_USER_DATA=$(cat "${USER_DATA_DIR}/chunk-test-node.sh")

# Inject S3_OUTPUT_PATH into the user-data
INJECTED_USER_DATA=$(printf 'export S3_OUTPUT_PATH="%s"\n%s' "$S3_OUTPUT_PATH" "$RAW_USER_DATA")
ENCODED_USER_DATA=$(echo "$INJECTED_USER_DATA" | base64 -w 0 2>/dev/null || echo "$INJECTED_USER_DATA" | base64)

# ---------------------------------------------------------------------------
# Resolve AMI
# ---------------------------------------------------------------------------
AMI=$(aws ec2 describe-images --region "$AWS_REGION" --owners 099720109477 \
    --filters Name=name,Values='ubuntu/images/hvm-ssd/ubuntu-jammy-22.04-amd64-server-*' Name=state,Values=available \
    --query 'sort_by(Images, &CreationDate)[-1].ImageId' --output text)
info "AMI: $AMI"

# ---------------------------------------------------------------------------
# Launch Spot instance
# ---------------------------------------------------------------------------
RUN_ARGS=(
    --region "$AWS_REGION"
    --image-id "$AMI"
    --instance-type "$INSTANCE_TYPE"
    --security-group-ids "$SG_ID"
    --subnet-id "$SUBNET_ID"
    --user-data "$ENCODED_USER_DATA"
    --block-device-mappings '[{"DeviceName":"/dev/sda1","Ebs":{"VolumeSize":30,"VolumeType":"gp3"}}]'
    --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=${PROJECT_TAG}},{Key=Project,Value=${PROJECT_TAG}}]"
    --instance-market-options '{"MarketType":"spot","SpotOptions":{"SpotInstanceType":"one-time","InstanceInterruptionBehavior":"terminate"}}'
)

if [ -n "$KEY_NAME" ]; then
    RUN_ARGS+=(--key-name "$KEY_NAME")
fi

info "Requesting Spot instance..."
INSTANCE_ID=$(aws ec2 run-instances "${RUN_ARGS[@]}" --query 'Instances[0].InstanceId' --output text)
info "Launched instance: $INSTANCE_ID"

# ---------------------------------------------------------------------------
# Wait for running state
# ---------------------------------------------------------------------------
info "Waiting for instance to be running..."
aws ec2 wait instance-running --region "$AWS_REGION" --instance-ids "$INSTANCE_ID"
sleep 5

PUBLIC_IP=$(aws ec2 describe-instances --region "$AWS_REGION" --instance-ids "$INSTANCE_ID" --query 'Reservations[0].Instances[0].PublicIpAddress' --output text)

# ---------------------------------------------------------------------------
# Output
# ---------------------------------------------------------------------------
echo ""
echo "============================================================================="
echo "                    CHUNK-ONLY TEST INSTANCE RUNNING"
echo "============================================================================="
echo ""
echo "  Instance ID: $INSTANCE_ID"
echo "  Public IP:   $PUBLIC_IP"
if [ -n "$KEY_NAME" ]; then
    echo "  SSH:         ssh -i ${KEY_NAME}.pem ubuntu@$PUBLIC_IP"
fi
echo ""
echo "  The instance will automatically:"
echo "    1. Install Spark"
echo "    2. Clone the repo"
echo "    3. Run chunk_only_pipeline.py -> $S3_OUTPUT_PATH"
echo "    4. Shut itself down when finished (or on failure)"
echo ""
echo "  Monitor progress live:"
if [ -n "$KEY_NAME" ]; then
    echo "    ssh -i ${KEY_NAME}.pem ubuntu@$PUBLIC_IP 'sudo tail -f /var/log/chunk-test.log'"
else
    echo "    (No KEY_NAME set — SSH not available. Use AWS Systems Manager Session Manager instead.)"
fi
echo ""
echo "  Check S3 output:"
echo "    aws s3 ls ${S3_OUTPUT_PATH/s3a:/s3:}"
echo ""
echo "  To cancel and terminate immediately:"
echo "    aws ec2 terminate-instances --region $AWS_REGION --instance-ids $INSTANCE_ID"
echo ""
echo "============================================================================="

# Save reference file
cat > "chunk-test-instance.txt" <<EOF
INSTANCE_ID=$INSTANCE_ID
PUBLIC_IP=$PUBLIC_IP
SG_ID=$SG_ID
REGION=$AWS_REGION
S3_OUTPUT_PATH=$S3_OUTPUT_PATH
EOF

info "Instance details saved to: chunk-test-instance.txt"
