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
# Extract bucket name and ensure bucket exists
# ---------------------------------------------------------------------------
BUCKET_NAME=$(echo "$S3_OUTPUT_PATH" | sed -n 's|s3a*://\([^/]*\).*|\1|p')
[ -z "$BUCKET_NAME" ] && error "Could not extract bucket name from S3_OUTPUT_PATH."
info "Target S3 bucket: $BUCKET_NAME"

# Check if bucket exists — head-bucket returns 0 on success, non-zero on failure
if aws s3api head-bucket --bucket "$BUCKET_NAME" --region "$AWS_REGION" 2>/dev/null; then
    info "Bucket already exists: $BUCKET_NAME"
else
    warn "Bucket '$BUCKET_NAME' not found. Creating it..."
    if [ "$AWS_REGION" == "us-east-1" ]; then
        aws s3api create-bucket --bucket "$BUCKET_NAME" --region "$AWS_REGION"
    else
        aws s3api create-bucket --bucket "$BUCKET_NAME" --region "$AWS_REGION" --create-bucket-configuration LocationConstraint="$AWS_REGION"
    fi
    info "Created bucket: $BUCKET_NAME"
fi

# ---------------------------------------------------------------------------
# Create IAM role + instance profile so EC2 can write to S3
# ---------------------------------------------------------------------------
ROLE_NAME="${PROJECT_TAG}-role"
PROFILE_NAME="${PROJECT_TAG}-profile"
POLICY_NAME="${PROJECT_TAG}-s3-policy"

ROLE_EXISTS=$(aws iam get-role --role-name "$ROLE_NAME" --query 'Role.RoleName' --output text 2>/dev/null || echo "none")

if [ "$ROLE_EXISTS" == "none" ]; then
    info "Creating IAM role and instance profile for S3 access..."

    # Trust policy for EC2
    cat > /tmp/trust-policy.json <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": { "Service": "ec2.amazonaws.com" },
      "Action": "sts:AssumeRole"
    }
  ]
}
EOF

    aws iam create-role --role-name "$ROLE_NAME" --assume-role-policy-document file:///tmp/trust-policy.json >/dev/null
    aws iam attach-role-policy --role-name "$ROLE_NAME" --policy-arn arn:aws:iam::aws:policy/AmazonS3FullAccess >/dev/null
    aws iam create-instance-profile --instance-profile-name "$PROFILE_NAME" >/dev/null
    aws iam add-role-to-instance-profile --instance-profile-name "$PROFILE_NAME" --role-name "$ROLE_NAME" >/dev/null

    # Wait a few seconds for IAM propagation
    sleep 5
    info "Created IAM role: $ROLE_NAME + profile: $PROFILE_NAME"
else
    info "Using existing IAM role: $ROLE_NAME"
fi

INSTANCE_PROFILE_ARN=$(aws iam get-instance-profile --instance-profile-name "$PROFILE_NAME" --query 'InstanceProfile.Arn' --output text)

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
SG_ID=$(aws ec2 describe-security-groups --region "$AWS_REGION" --filters Name=group-name,Values="$SG_NAME" Name=vpc-id,Values="$VPC_ID" --query 'SecurityGroups[0].GroupId' --output text 2>/dev/null || echo "")

# Normalize: AWS CLI can return literal "None" when nothing is found
if [ -z "$SG_ID" ] || [ "$SG_ID" == "None" ]; then
    info "Creating security group '$SG_NAME' in VPC $VPC_ID..."
    SG_ID=$(aws ec2 create-security-group --region "$AWS_REGION" --group-name "$SG_NAME" --description "SG for chunking test" --vpc-id "$VPC_ID" --query 'GroupId' --output text)

    # Ingress: SSH only from caller's IP
    CALLER_IP=$(curl -s https://checkip.amazonaws.com)/32
    info "Your public IP: $CALLER_IP — restricting SSH to this IP"
    aws ec2 authorize-security-group-ingress --region "$AWS_REGION" --group-id "$SG_ID" --protocol tcp --port 22 --cidr "$CALLER_IP" >/dev/null || true

    # Ingress: allow all traffic between instances in this SG (vLLM <-> Spark <-> Weaviate)
    aws ec2 authorize-security-group-ingress --region "$AWS_REGION" --group-id "$SG_ID" --protocol all --source-group "$SG_ID" >/dev/null || true

    # Egress: HTTPS (S3, apt, pip, git), HTTP (apt repos), DNS (TCP+UDP)
    aws ec2 authorize-security-group-egress --region "$AWS_REGION" --group-id "$SG_ID" --protocol tcp --port 443 --cidr 0.0.0.0/0 >/dev/null || true
    aws ec2 authorize-security-group-egress --region "$AWS_REGION" --group-id "$SG_ID" --protocol tcp --port 80 --cidr 0.0.0.0/0 >/dev/null || true
    aws ec2 authorize-security-group-egress --region "$AWS_REGION" --group-id "$SG_ID" --protocol udp --port 53 --cidr 0.0.0.0/0 >/dev/null || true
    aws ec2 authorize-security-group-egress --region "$AWS_REGION" --group-id "$SG_ID" --protocol tcp --port 53 --cidr 0.0.0.0/0 >/dev/null || true

    # Remove default all-traffic egress rule that AWS creates automatically
    aws ec2 revoke-security-group-egress --region "$AWS_REGION" --group-id "$SG_ID" --protocol all --cidr 0.0.0.0/0 >/dev/null || true

    info "Created security group: $SG_ID (tight rules)"
else
    info "Using existing security group: $SG_ID"
fi

# Final sanity check
if [ -z "$SG_ID" ] || [ "$SG_ID" == "None" ]; then
    error "Security group ID is still empty after creation attempt. Check AWS permissions."
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
# Launch instance — try Spot first, fall back to On-Demand
# ---------------------------------------------------------------------------

BASE_ARGS=(
    --region "$AWS_REGION"
    --image-id "$AMI"
    --instance-type "$INSTANCE_TYPE"
    --security-group-ids "$SG_ID"
    --user-data "$ENCODED_USER_DATA"
    --iam-instance-profile "Name=$PROFILE_NAME"
    --block-device-mappings '[{"DeviceName":"/dev/sda1","Ebs":{"VolumeSize":30,"VolumeType":"gp3"}}]'
    --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=${PROJECT_TAG}},{Key=Project,Value=${PROJECT_TAG}}]"
)

if [ -n "$KEY_NAME" ]; then
    BASE_ARGS+=(--key-name "$KEY_NAME")
fi

info "Requesting Spot instance ($INSTANCE_TYPE)..."
SPOT_ARGS=("${BASE_ARGS[@]}")
SPOT_ARGS+=(--instance-market-options '{"MarketType":"spot","SpotOptions":{"SpotInstanceType":"one-time","InstanceInterruptionBehavior":"terminate"}}')

# Temporarily disable set -e so failed Spot request doesn't kill the script
set +e
SPOT_OUTPUT=$(aws ec2 run-instances "${SPOT_ARGS[@]}" --query 'Instances[0].InstanceId' --output text 2>&1)
SPOT_EXIT=$?
set -e

if [ $SPOT_EXIT -ne 0 ] || [ -z "$SPOT_OUTPUT" ] || [ "$SPOT_OUTPUT" == "None" ]; then
    warn "Spot capacity unavailable for $INSTANCE_TYPE."
    warn "  Reason: $(echo "$SPOT_OUTPUT" | head -1)"
    warn "Falling back to On-Demand..."
    set +e
    INSTANCE_ID=$(aws ec2 run-instances "${BASE_ARGS[@]}" --query 'Instances[0].InstanceId' --output text 2>&1)
    ONDEMAND_EXIT=$?
    set -e
    if [ $ONDEMAND_EXIT -ne 0 ] || [ -z "$INSTANCE_ID" ] || [ "$INSTANCE_ID" == "None" ]; then
        error "On-Demand launch also failed: $INSTANCE_ID. Try a different instance type (export INSTANCE_TYPE=m5a.large)"
    fi
    info "Launched On-Demand instance: $INSTANCE_ID"
else
    INSTANCE_ID="$SPOT_OUTPUT"
    info "Launched Spot instance: $INSTANCE_ID"
fi

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
