#!/bin/bash
set -e

# =============================================================================
# AWS EMR Chunking Test Launcher
# =============================================================================
# Launches a cheap EMR cluster with Spark pre-installed, runs the CORD-19
# chunking pipeline, streams every log line to your terminal, and
# auto-terminates the cluster when done.
#
# Cost estimate (us-east-1, Spot):
#   1 x m5.xlarge master  ~ $0.05/hr Spot
#   1 x m5.xlarge core    ~ $0.05/hr Spot
#   EMR surcharge          ~ 6.5%
#   Total                  ~ $0.11/hr  => under $1 for a full test run
#
# Requirements:
#   - AWS CLI installed and configured
#   - An S3 bucket for output (created automatically if needed)
#
# Usage:
#   export S3_OUTPUT_PATH=s3a://vllm-chunking/cord19-chunks/
#   export KEY_NAME=my-key   # optional, for SSH debug
#   ./emr-chunking-test.sh
# =============================================================================

AWS_REGION=${AWS_REGION:-us-east-1}
KEY_NAME=${KEY_NAME:-""}
MASTER_INSTANCE=${MASTER_INSTANCE:-m5.xlarge}
CORE_INSTANCE=${CORE_INSTANCE:-m5.xlarge}
CORE_COUNT=${CORE_COUNT:-1}
PROJECT_TAG="spark-vlm-rag-emr-test"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

info()  { echo -e "${GREEN}[INFO]${NC} $1"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $1"; }
error() { echo -e "${RED}[ERROR]${NC} $1"; exit 1; }
phase() { echo -e "\n${CYAN}━━━ $1 ━━━${NC}"; }
step()  { echo -e "  ${CYAN}▸${NC} $1"; }

# ---------------------------------------------------------------------------
# Validate prerequisites
# ---------------------------------------------------------------------------
command -v aws >/dev/null 2>&1 || error "AWS CLI not found."
aws sts get-caller-identity >/dev/null 2>&1 || error "AWS CLI not authenticated."
[ -z "$S3_OUTPUT_PATH" ] && error "S3_OUTPUT_PATH must be set (e.g., s3a://vllm-chunking/cord19-chunks/)"

ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)

info "Region:           $AWS_REGION"
info "Output:           $S3_OUTPUT_PATH"
info "Master instance:  $MASTER_INSTANCE"
info "Core instances:   $CORE_COUNT x $CORE_INSTANCE"

# ---------------------------------------------------------------------------
# Extract bucket name and ensure bucket + log path exist
# ---------------------------------------------------------------------------
BUCKET_NAME=$(echo "$S3_OUTPUT_PATH" | sed -n 's|s3a*://\([^/]*\).*|\1|p')
[ -z "$BUCKET_NAME" ] && error "Could not extract bucket name from S3_OUTPUT_PATH."

phase "S3 BUCKET"
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

# EMR logs bucket (same bucket, different prefix)
EMR_LOG_PATH="s3://$BUCKET_NAME/emr-logs/"
step "EMR logs will be written to: $EMR_LOG_PATH"

# ---------------------------------------------------------------------------
# Upload Spark job files to S3 so EMR can access them
# ---------------------------------------------------------------------------
phase "UPLOAD JOB FILES"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
JOB_S3_PREFIX="s3://$BUCKET_NAME/spark-jobs/"

step "Uploading spark_jobs/ to $JOB_S3_PREFIX ..."
aws s3 sync "$PROJECT_DIR/spark_jobs/" "$JOB_S3_PREFIX" --quiet
info "Job files uploaded."

# ---------------------------------------------------------------------------
# Ensure EMR service roles exist
# ---------------------------------------------------------------------------
phase "IAM ROLES"

EMR_ROLE="EMR_DefaultRole"
EMR_EC2_ROLE="EMR_EC2_DefaultRole"

set +e
aws iam get-role --role-name "$EMR_ROLE" >/dev/null 2>&1
ROLE1_EXISTS=$?
aws iam get-role --role-name "$EMR_EC2_ROLE" >/dev/null 2>&1
ROLE2_EXISTS=$?
set -e

if [ $ROLE1_EXISTS -ne 0 ]; then
    step "Creating $EMR_ROLE ..."
    aws iam create-role --role-name "$EMR_ROLE" --assume-role-policy-document '{"Version":"2008-10-17","Statement":[{"Sid":"","Effect":"Allow","Principal":{"Service":"elasticmapreduce.amazonaws.com"},"Action":"sts:AssumeRole"}]}' >/dev/null 2>&1 || true
    aws iam attach-role-policy --role-name "$EMR_ROLE" --policy-arn arn:aws:iam::aws:policy/service-role/AmazonElasticMapReduceRole >/dev/null 2>&1 || true
    info "Created $EMR_ROLE"
else
    step "Using existing $EMR_ROLE"
fi

if [ $ROLE2_EXISTS -ne 0 ]; then
    step "Creating $EMR_EC2_ROLE ..."
    aws iam create-role --role-name "$EMR_EC2_ROLE" --assume-role-policy-document '{"Version":"2008-10-17","Statement":[{"Sid":"","Effect":"Allow","Principal":{"Service":"ec2.amazonaws.com"},"Action":"sts:AssumeRole"}]}' >/dev/null 2>&1 || true
    aws iam attach-role-policy --role-name "$EMR_EC2_ROLE" --policy-arn arn:aws:iam::aws:policy/service-role/AmazonElasticMapReduceforEC2Role >/dev/null 2>&1 || true
    aws iam create-instance-profile --instance-profile-name "$EMR_EC2_ROLE" >/dev/null 2>&1 || true
    sleep 5
    aws iam add-role-to-instance-profile --instance-profile-name "$EMR_EC2_ROLE" --role-name "$EMR_EC2_ROLE" >/dev/null 2>&1 || true
    info "Created $EMR_EC2_ROLE + instance profile"
else
    step "Using existing $EMR_EC2_ROLE"
fi

# Wait for IAM propagation
step "Waiting for IAM propagation (10s)..."
sleep 10

# ---------------------------------------------------------------------------
# Security group — reuse existing or create minimal one
# ---------------------------------------------------------------------------
phase "SECURITY GROUP"
SG_NAME="${PROJECT_TAG}-sg"
VPC_ID=$(aws ec2 describe-vpcs --region "$AWS_REGION" --filters Name=isDefault,Values=true --query 'Vpcs[0].VpcId' --output text)
[ "$VPC_ID" == "None" ] && error "No default VPC found."

SG_ID=$(aws ec2 describe-security-groups --region "$AWS_REGION" --filters Name=group-name,Values="$SG_NAME" Name=vpc-id,Values="$VPC_ID" --query 'SecurityGroups[0].GroupId' --output text 2>/dev/null || echo "")

if [ -z "$SG_ID" ] || [ "$SG_ID" == "None" ]; then
    step "Creating security group '$SG_NAME' in VPC $VPC_ID..."
    SG_ID=$(aws ec2 create-security-group --region "$AWS_REGION" --group-name "$SG_NAME" --description "SG for EMR chunking test" --vpc-id "$VPC_ID" --query 'GroupId' --output text)

    # Ingress: SSH from caller IP
    CALLER_IP=$(curl -s https://checkip.amazonaws.com)/32
    step "Restricting SSH to your IP: $CALLER_IP"
    aws ec2 authorize-security-group-ingress --region "$AWS_REGION" --group-id "$SG_ID" --protocol tcp --port 22 --cidr "$CALLER_IP" >/dev/null || true

    # Ingress: intra-group traffic (EMR nodes must talk to each other)
    aws ec2 authorize-security-group-ingress --region "$AWS_REGION" --group-id "$SG_ID" --protocol all --source-group "$SG_ID" >/dev/null || true

    # Egress: HTTPS, HTTP, DNS only
    aws ec2 authorize-security-group-egress --region "$AWS_REGION" --group-id "$SG_ID" --protocol tcp --port 443 --cidr 0.0.0.0/0 >/dev/null || true
    aws ec2 authorize-security-group-egress --region "$AWS_REGION" --group-id "$SG_ID" --protocol tcp --port 80 --cidr 0.0.0.0/0 >/dev/null || true
    aws ec2 authorize-security-group-egress --region "$AWS_REGION" --group-id "$SG_ID" --protocol udp --port 53 --cidr 0.0.0.0/0 >/dev/null || true
    aws ec2 authorize-security-group-egress --region "$AWS_REGION" --group-id "$SG_ID" --protocol tcp --port 53 --cidr 0.0.0.0/0 >/dev/null || true

    # Remove default all-traffic egress
    aws ec2 revoke-security-group-egress --region "$AWS_REGION" --group-id "$SG_ID" --protocol all --cidr 0.0.0.0/0 >/dev/null || true

    info "Created security group: $SG_ID"
else
    info "Using existing security group: $SG_ID"
fi

# ---------------------------------------------------------------------------
# Launch EMR cluster
# ---------------------------------------------------------------------------
phase "LAUNCH EMR CLUSTER"

CLUSTER_NAME="chunking-test-$(date +%Y%m%d-%H%M%S)"

step "Creating EMR cluster '$CLUSTER_NAME'..."

EMR_ARGS=(
    --name "$CLUSTER_NAME"
    --region "$AWS_REGION"
    --release-label emr-7.3.0
    --applications Name=Spark Name=Hadoop
    --service-role "$EMR_ROLE"
    --job-flow-role "$EMR_EC2_ROLE"
    --log-uri "$EMR_LOG_PATH"
    --auto-termination-policy IdleTimeout=300
    --tags Project="$PROJECT_TAG"
    --ec2-attributes "KeyName=${KEY_NAME},SubnetId=default,SecurityGroups=$SG_ID,AdditionalMasterSecurityGroups=$SG_ID,AdditionalSlaveSecurityGroups=$SG_ID"
    --instance-groups
        InstanceGroupType=MASTER,InstanceCount=1,InstanceType=$MASTER_INSTANCE,Name=Master,Market=SPOT,SpotPrice=0.10
        InstanceGroupType=CORE,InstanceCount=$CORE_COUNT,InstanceType=$CORE_INSTANCE,Name=Core,Market=SPOT,SpotPrice=0.10
)

set +e
CLUSTER_ID=$(aws emr create-cluster "${EMR_ARGS[@]}" --query ClusterId --output text 2>&1)
CREATE_EXIT=$?
set -e

if [ $CREATE_EXIT -ne 0 ] || [ -z "$CLUSTER_ID" ] || [ "$CLUSTER_ID" == "None" ]; then
    warn "Spot cluster creation failed. Trying On-Demand..."
    EMR_ARGS=(
        --name "$CLUSTER_NAME"
        --region "$AWS_REGION"
        --release-label emr-7.3.0
        --applications Name=Spark Name=Hadoop
        --service-role "$EMR_ROLE"
        --job-flow-role "$EMR_EC2_ROLE"
        --log-uri "$EMR_LOG_PATH"
        --auto-termination-policy IdleTimeout=300
        --tags Project="$PROJECT_TAG"
        --ec2-attributes "KeyName=${KEY_NAME},SubnetId=default,SecurityGroups=$SG_ID,AdditionalMasterSecurityGroups=$SG_ID,AdditionalSlaveSecurityGroups=$SG_ID"
        --instance-groups
            InstanceGroupType=MASTER,InstanceCount=1,InstanceType=$MASTER_INSTANCE,Name=Master
            InstanceGroupType=CORE,InstanceCount=$CORE_COUNT,InstanceType=$CORE_INSTANCE,Name=Core
    )

    set +e
    CLUSTER_ID=$(aws emr create-cluster "${EMR_ARGS[@]}" --query ClusterId --output text 2>&1)
    CREATE_EXIT=$?
    set -e

    if [ $CREATE_EXIT -ne 0 ] || [ -z "$CLUSTER_ID" ] || [ "$CLUSTER_ID" == "None" ]; then
        error "EMR cluster creation failed: $CLUSTER_ID"
    fi
    info "Launched On-Demand EMR cluster: $CLUSTER_ID"
else
    info "Launched Spot EMR cluster: $CLUSTER_ID"
fi

# Save reference for cleanup
cat > "emr-test-cluster.txt" <<EOF
CLUSTER_ID=$CLUSTER_ID
REGION=$AWS_REGION
S3_OUTPUT_PATH=$S3_OUTPUT_PATH
SG_ID=$SG_ID
EOF

# ---------------------------------------------------------------------------
# Wait for cluster to be ready
# ---------------------------------------------------------------------------
phase "WAIT FOR CLUSTER"
step "Waiting for EMR cluster $CLUSTER_ID to start..."
step "This usually takes 3-5 minutes (Spark is pre-installed, no manual setup)."

LAST_STATE=""
while true; do
    STATE=$(aws emr describe-cluster --cluster-id "$CLUSTER_ID" --region "$AWS_REGION" --query 'Cluster.Status.State' --output text 2>/dev/null || echo "unknown")

    if [ "$STATE" != "$LAST_STATE" ]; then
        echo "  [$(date '+%H:%M:%S')] Cluster state: $STATE"
        LAST_STATE="$STATE"
    fi

    case $STATE in
        WAITING)
            info "Cluster is ready!"
            break
            ;;
        STARTING|BOOTSTRAPPING)
            sleep 15
            ;;
        TERMINATED|TERMINATED_WITH_ERRORS)
            REASON=$(aws emr describe-cluster --cluster-id "$CLUSTER_ID" --region "$AWS_REGION" --query 'Cluster.Status.StateChangeReason.Message' --output text 2>/dev/null)
            error "Cluster terminated unexpectedly: $REASON"
            ;;
        *)
            sleep 10
            ;;
    esac
done

# ---------------------------------------------------------------------------
# Submit Spark step
# ---------------------------------------------------------------------------
phase "SUBMIT SPARK JOB"

# Build spark-submit args for EMR YARN
SPARK_ARGS="--conf spark.sql.adaptive.enabled=true"
STEP_ARGS=(
    --cluster-id "$CLUSTER_ID"
    --region "$AWS_REGION"
    --action-type CUSTOM_JAR
    --name "CORD19-ChunkOnly"
    --jar "command-runner.jar"
    --arguments "spark-submit,${SPARK_ARGS},--master,yarn,--deploy-mode,cluster,--py-files,${JOB_S3_PREFIX}config.py,${JOB_S3_PREFIX}chunk_only_pipeline.py"
    --step-type CUSTOM_JAR
)

step "Submitting Spark step to EMR..."
STEP_ID=$(aws emr add-steps "${STEP_ARGS[@]}" --query 'StepIds[0]' --output text)
info "Step submitted: $STEP_ID"

# ---------------------------------------------------------------------------
# Stream step progress to terminal
# ---------------------------------------------------------------------------
phase "MONITOR SPARK JOB"
step "Streaming job progress to terminal..."
step "Spark UI available on master node (see below for URL)"
echo ""

LAST_STEP_STATE=""
LOG_CURSOR=""  # track what we've already printed

while true; do
    STEP_STATE=$(aws emr describe-step --cluster-id "$CLUSTER_ID" --step-id "$STEP_ID" --region "$AWS_REGION" --query 'Step.Status.State' --output text 2>/dev/null || echo "unknown")

    if [ "$STEP_STATE" != "$LAST_STEP_STATE" ]; then
        echo "  [$(date '+%H:%M:%S')] Step state: $STEP_STATE"
        LAST_STEP_STATE="$STEP_STATE"
    fi

    # Try to stream Spark step log from S3
    # EMR writes logs to: s3://bucket/emr-logs/j-CLUSTERID/steps/STEPID/
    if [ -n "$STEP_ID" ]; then
        STEP_LOG_PREFIX="s3://$BUCKET_NAME/emr-logs/${CLUSTER_ID}/steps/${STEP_ID}/"
        # Try to get the stdout.gz log
        TEMP_LOG=$(mktemp)
        set +e
        aws s3 cp "${STEP_LOG_PREFIX}stdout.gz" "$TEMP_LOG" --quiet 2>/dev/null
        if [ $? -eq 0 ]; then
            NEW_CONTENT=$(zcat "$TEMP_LOG" 2>/dev/null | tail -50)
            if [ -n "$NEW_CONTENT" ] && [ "$NEW_CONTENT" != "$LOG_CURSOR" ]; then
                # Show only the new lines
                if [ -n "$LOG_CURSOR" ]; then
                    echo "$NEW_CONTENT" | grep -v -F "$(echo "$LOG_CURSOR" | tail -1)" | tail -20
                else
                    echo "$NEW_CONTENT" | tail -20
                fi
                LOG_CURSOR="$NEW_CONTENT"
            fi
        fi
        rm -f "$TEMP_LOG"
        set -e
    fi

    case $STEP_STATE in
        COMPLETED)
            echo ""
            info "Spark job completed SUCCESSFULLY!"
            break
            ;;
        FAILED|INTERRUPTED)
            echo ""
            error "Spark job FAILED! Check logs at: ${STEP_LOG_PREFIX}"
            ;;
        TERMINATED)
            echo ""
            error "Spark job was TERMINATED."
            ;;
        PENDING|RUNNING)
            sleep 10
            ;;
        *)
            sleep 10
            ;;
    esac
done

# ---------------------------------------------------------------------------
# Wait for auto-termination (or terminate manually)
# ---------------------------------------------------------------------------
phase "CLUSTER SHUTDOWN"

info "Cluster will auto-terminate after 5 min idle (IdleTimeout=300)."
step "You can also terminate it now..."

set +e
read -t 15 -p "  Terminate cluster now? [Y/n] " TERMINATE_CHOICE 2>/dev/null || TERMINATE_CHOICE="y"
set -e

if [[ "$TERMINATE_CHOICE" =~ ^[Nn] ]]; then
    warn "Cluster $CLUSTER_ID left running. Terminate later with:"
    warn "  aws emr terminate-clusters --cluster-ids $CLUSTER_ID"
else
    step "Terminating cluster $CLUSTER_ID ..."
    aws emr terminate-clusters --cluster-ids "$CLUSTER_ID" --region "$AWS_REGION"
    info "Cluster termination requested."
fi

# ---------------------------------------------------------------------------
# Check S3 output
# ---------------------------------------------------------------------------
phase "VERIFY OUTPUT"
info "Checking S3 output..."
aws s3 ls "${S3_OUTPUT_PATH/s3a:/s3:}" 2>/dev/null || warn "No output found yet at $S3_OUTPUT_PATH"

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
info "DONE!"
info "  Cluster ID:    $CLUSTER_ID"
info "  S3 output:     $S3_OUTPUT_PATH"
info "  EMR logs:      $EMR_LOG_PATH"
info "  Details saved: emr-test-cluster.txt"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
