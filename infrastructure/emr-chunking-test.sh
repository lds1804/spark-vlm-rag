#!/bin/bash
set -e

# =============================================================================
# AWS EMR Chunking Test Launcher
# =============================================================================
# Launches a cheap EMR cluster with Spark pre-installed, runs the CORD-19
# chunking pipeline, streams every log line live to your terminal, and
# auto-terminates when done.
#
# Cost estimate (us-east-1, Spot):
#   1 x m5.large master   ~ $0.03/hr
#   1 x m5.large core     ~ $0.03/hr
#   EMR surcharge          ~ 6.5%
#   Total                 ~ $0.06/hr  => ~$0.20 for a full test run
#
# Usage:
#   export S3_OUTPUT_PATH=s3a://vllm-chunking/cord19-chunks/
#   export KEY_NAME=my-key   # strongly recommended for live log streaming
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

info()  { echo -e "${GREEN}[INFO]${NC}  $1"; }
warn()  { echo -e "${YELLOW}[WARN]${NC}  $1"; }
error() { echo -e "${RED}[ERROR]${NC} $1"; exit 1; }
phase() { echo -e "\n${CYAN}━━━ $1 ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"; }
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
[ -n "$KEY_NAME" ] && info "Key pair:         $KEY_NAME (SSH live log streaming enabled)"
[ -z "$KEY_NAME" ] && warn "No KEY_NAME set — will fall back to S3 log polling (less real-time)"

# ---------------------------------------------------------------------------
# Extract bucket name and ensure it exists
# ---------------------------------------------------------------------------
BUCKET_NAME=$(echo "$S3_OUTPUT_PATH" | sed -n 's|s3a*://\([^/]*\).*|\1|p')
[ -z "$BUCKET_NAME" ] && error "Could not extract bucket name from S3_OUTPUT_PATH."

phase "S3 BUCKET"
if aws s3api head-bucket --bucket "$BUCKET_NAME" --region "$AWS_REGION" 2>/dev/null; then
    info "Bucket already exists: $BUCKET_NAME"
else
    warn "Bucket '$BUCKET_NAME' not found. Creating it..."
    if [ "$AWS_REGION" == "us-east-1" ]; then
        aws s3api create-bucket --bucket "$BUCKET_NAME" --region "$AWS_REGION" >/dev/null
    else
        aws s3api create-bucket --bucket "$BUCKET_NAME" --region "$AWS_REGION" \
            --create-bucket-configuration LocationConstraint="$AWS_REGION" >/dev/null
    fi
    info "Created bucket: $BUCKET_NAME"
fi

EMR_LOG_PATH="s3://$BUCKET_NAME/emr-logs/"
step "EMR logs path: $EMR_LOG_PATH"

# ---------------------------------------------------------------------------
# Upload Spark job files to S3
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

for ROLE in "$EMR_ROLE" "$EMR_EC2_ROLE"; do
    set +e
    aws iam get-role --role-name "$ROLE" >/dev/null 2>&1
    EXISTS=$?
    set -e
    if [ $EXISTS -ne 0 ]; then
        step "Creating missing role: $ROLE"
        if [ "$ROLE" == "$EMR_ROLE" ]; then
            TRUST='{"Version":"2008-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":"elasticmapreduce.amazonaws.com"},"Action":"sts:AssumeRole"}]}'
            POLICY="arn:aws:iam::aws:policy/service-role/AmazonElasticMapReduceRole"
        else
            TRUST='{"Version":"2008-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":"ec2.amazonaws.com"},"Action":"sts:AssumeRole"}]}'
            POLICY="arn:aws:iam::aws:policy/service-role/AmazonElasticMapReduceforEC2Role"
        fi
        aws iam create-role --role-name "$ROLE" --assume-role-policy-document "$TRUST" >/dev/null
        aws iam attach-role-policy --role-name "$ROLE" --policy-arn "$POLICY" >/dev/null
        if [ "$ROLE" == "$EMR_EC2_ROLE" ]; then
            aws iam create-instance-profile --instance-profile-name "$ROLE" >/dev/null 2>&1 || true
            sleep 5
            aws iam add-role-to-instance-profile --instance-profile-name "$ROLE" --role-name "$ROLE" >/dev/null 2>&1 || true
        fi
        info "Created role: $ROLE"
    else
        step "Using existing role: $ROLE"
    fi
done

step "Waiting for IAM propagation (10s)..."
sleep 10

# ---------------------------------------------------------------------------
# Security group (EMR nodes)
# ---------------------------------------------------------------------------
phase "SECURITY GROUP"

SG_NAME="${PROJECT_TAG}-sg"
VPC_ID=$(aws ec2 describe-vpcs --region "$AWS_REGION" --filters Name=isDefault,Values=true \
    --query 'Vpcs[0].VpcId' --output text)
[ "$VPC_ID" == "None" ] || [ -z "$VPC_ID" ] && error "No default VPC found."

# Get a real subnet ID (EMR needs an actual SubnetId, not "default")
SUBNET_ID=$(aws ec2 describe-subnets --region "$AWS_REGION" \
    --filters Name=vpc-id,Values="$VPC_ID" Name=default-for-az,Values=true \
    --query 'Subnets[0].SubnetId' --output text)
[ "$SUBNET_ID" == "None" ] || [ -z "$SUBNET_ID" ] && error "No default subnet found in VPC $VPC_ID."
step "Using subnet: $SUBNET_ID"

SG_ID=$(aws ec2 describe-security-groups --region "$AWS_REGION" \
    --filters Name=group-name,Values="$SG_NAME" Name=vpc-id,Values="$VPC_ID" \
    --query 'SecurityGroups[0].GroupId' --output text 2>/dev/null || echo "")

if [ -z "$SG_ID" ] || [ "$SG_ID" == "None" ]; then
    step "Creating security group '$SG_NAME' in VPC $VPC_ID..."
    SG_ID=$(aws ec2 create-security-group --region "$AWS_REGION" \
        --group-name "$SG_NAME" --description "SG for EMR chunking test" \
        --vpc-id "$VPC_ID" --query 'GroupId' --output text)

    CALLER_IP=$(curl -s https://checkip.amazonaws.com)/32
    step "Restricting SSH to your IP: $CALLER_IP"

    # Ingress: SSH from caller IP only
    aws ec2 authorize-security-group-ingress --region "$AWS_REGION" --group-id "$SG_ID" --protocol tcp --port 22 --cidr "$CALLER_IP" >/dev/null || true
    # Ingress: all traffic between nodes in the same SG
    aws ec2 authorize-security-group-ingress --region "$AWS_REGION" --group-id "$SG_ID" --protocol all --source-group "$SG_ID" >/dev/null || true
    # Egress: HTTPS, HTTP, DNS
    aws ec2 authorize-security-group-egress --region "$AWS_REGION" --group-id "$SG_ID" --protocol tcp --port 443 --cidr 0.0.0.0/0 >/dev/null || true
    aws ec2 authorize-security-group-egress --region "$AWS_REGION" --group-id "$SG_ID" --protocol tcp --port 80  --cidr 0.0.0.0/0 >/dev/null || true
    aws ec2 authorize-security-group-egress --region "$AWS_REGION" --group-id "$SG_ID" --protocol udp --port 53  --cidr 0.0.0.0/0 >/dev/null || true
    aws ec2 authorize-security-group-egress --region "$AWS_REGION" --group-id "$SG_ID" --protocol tcp --port 53  --cidr 0.0.0.0/0 >/dev/null || true
    # Remove default all-traffic egress
    aws ec2 revoke-security-group-egress --region "$AWS_REGION" --group-id "$SG_ID" --protocol all --cidr 0.0.0.0/0 >/dev/null || true

    info "Created security group: $SG_ID"
else
    info "Using existing security group: $SG_ID"
fi

# ---------------------------------------------------------------------------
# Build ec2-attributes string (no SecurityGroups param — use Additional*)
# ---------------------------------------------------------------------------
EC2_ATTRS="SubnetId=${SUBNET_ID},InstanceProfile=${EMR_EC2_ROLE},AdditionalMasterSecurityGroups=${SG_ID},AdditionalSlaveSecurityGroups=${SG_ID}"
[ -n "$KEY_NAME" ] && EC2_ATTRS="KeyName=${KEY_NAME},${EC2_ATTRS}"

# ---------------------------------------------------------------------------
# Debug/Persistence Logic: Check for existing cluster
# ---------------------------------------------------------------------------
SESSION_FILE="emr-session.env"
[ -f "$SESSION_FILE" ] && source "$SESSION_FILE"

if [ -n "$CLUSTER_ID" ]; then
    step "Checking if existing cluster $CLUSTER_ID is still active..."
    STATE=$(aws emr describe-cluster --cluster-id "$CLUSTER_ID" --region "$AWS_REGION" --query 'Cluster.Status.State' --output text 2>/dev/null || echo "not-found")
    if [[ "$STATE" =~ ^(WAITING|RUNNING|STARTING|BOOTSTRAPPING)$ ]]; then
        info "Re-using existing cluster: $CLUSTER_ID (State: $STATE)"
        SKIP_LAUNCH=true
    else
        warn "Cluster $CLUSTER_ID is in state $STATE. Launching a new one..."
        unset CLUSTER_ID
    fi
fi

# ---------------------------------------------------------------------------
# Launch EMR cluster (Spot, fallback to On-Demand)
# ---------------------------------------------------------------------------
phase "LAUNCH EMR CLUSTER"

if [ "$SKIP_LAUNCH" = true ]; then
    step "Skipping cluster creation."
else
    CLUSTER_NAME="chunking-test-$(date +%Y%m%d-%H%M%S)"
    step "Cluster name: $CLUSTER_NAME"

    try_launch_cluster() {
        local SPOT="$1"
        local ARGS=(
            --name "$CLUSTER_NAME"
            --region "$AWS_REGION"
            --release-label emr-7.3.0
            --applications Name=Spark Name=Hadoop
            --service-role "$EMR_ROLE"
            --log-uri "$EMR_LOG_PATH"
            --auto-termination-policy IdleTimeout=14400 # 4 hours for debug mode
            --tags "Project=$PROJECT_TAG"
            --ec2-attributes "$EC2_ATTRS"
            --bootstrap-actions
            "Path=${JOB_S3_PREFIX}emr-bootstrap.sh"
        )
        if [ "$SPOT" == "yes" ]; then
            ARGS+=(--instance-groups
                "InstanceGroupType=MASTER,InstanceCount=1,InstanceType=$MASTER_INSTANCE,Name=Master,Market=SPOT,BidPrice=0.15"
                "InstanceGroupType=CORE,InstanceCount=$CORE_COUNT,InstanceType=$CORE_INSTANCE,Name=Core,Market=SPOT,BidPrice=0.15")
        else
            ARGS+=(--instance-groups
                "InstanceGroupType=MASTER,InstanceCount=1,InstanceType=$MASTER_INSTANCE,Name=Master"
                "InstanceGroupType=CORE,InstanceCount=$CORE_COUNT,InstanceType=$CORE_INSTANCE,Name=Core")
        fi
        aws emr create-cluster "${ARGS[@]}" --query ClusterId --output text 2>&1
    }

    step "Trying Spot cluster..."
    set +e
    RESULT=$(try_launch_cluster yes)
    CREATE_EXIT=$?
    set -e

    if [ $CREATE_EXIT -ne 0 ] || [ -z "$RESULT" ] || [ "$RESULT" == "None" ]; then
        warn "Spot failed: $(echo "$RESULT" | head -1)"
        warn "Falling back to On-Demand..."
        set +e
        RESULT=$(try_launch_cluster no)
        CREATE_EXIT=$?
        set -e
        [ $CREATE_EXIT -ne 0 ] || [ -z "$RESULT" ] || [ "$RESULT" == "None" ] && error "EMR creation failed: $RESULT"
        CLUSTER_ID="$RESULT"
        info "Launched On-Demand cluster: $CLUSTER_ID"
    else
        CLUSTER_ID="$RESULT"
        info "Launched Spot cluster: $CLUSTER_ID"
    fi

    # Persist for next run
    echo "export CLUSTER_ID=$CLUSTER_ID" > "$SESSION_FILE"
    info "Cluster ID persisted to $SESSION_FILE"
fi

cat > "emr-test-cluster.txt" <<EOF
CLUSTER_ID=$CLUSTER_ID
REGION=$AWS_REGION
S3_OUTPUT_PATH=$S3_OUTPUT_PATH
SG_ID=$SG_ID
EOF

echo ""
info "To terminate at any time: aws emr terminate-clusters --cluster-ids $CLUSTER_ID --region $AWS_REGION"

# ---------------------------------------------------------------------------
# Wait for cluster WAITING state
# ---------------------------------------------------------------------------
phase "WAIT FOR CLUSTER"
step "Waiting for EMR cluster to be ready (3-5 min, Spark pre-installed)..."

LAST_STATE=""
while true; do
    STATE=$(aws emr describe-cluster --cluster-id "$CLUSTER_ID" --region "$AWS_REGION" \
        --query 'Cluster.Status.State' --output text 2>/dev/null || echo "unknown")

    [ "$STATE" != "$LAST_STATE" ] && echo "  [$(date '+%H:%M:%S')] Cluster state: $STATE"
    LAST_STATE="$STATE"

    case $STATE in
        WAITING)       info "Cluster is ready!"; break ;;
        STARTING|BOOTSTRAPPING|PROVISIONING) sleep 15 ;;
        TERMINATED|TERMINATED_WITH_ERRORS)
            REASON=$(aws emr describe-cluster --cluster-id "$CLUSTER_ID" --region "$AWS_REGION" \
                --query 'Cluster.Status.StateChangeReason.Message' --output text 2>/dev/null)
            error "Cluster terminated: $REASON" ;;
        *)             sleep 10 ;;
    esac
done

MASTER_DNS=$(aws emr describe-cluster --cluster-id "$CLUSTER_ID" --region "$AWS_REGION" \
    --query 'Cluster.MasterPublicDnsName' --output text 2>/dev/null || echo "")
[ -n "$MASTER_DNS" ] && info "Master DNS: $MASTER_DNS"

# ---------------------------------------------------------------------------
# Submit Spark step
# ---------------------------------------------------------------------------
phase "SUBMIT SPARK JOB"

    SUBMIT_JOB=${SUBMIT_JOB:-ingest_to_lancedb.py}
    
    STEP_ID=$(aws emr add-steps \
        --cluster-id "$CLUSTER_ID" \
        --region "$AWS_REGION" \
        --steps "Type=Spark,Name=RAG-Ingestion,ActionOnFailure=CONTINUE,Args=[--master,yarn,--deploy-mode,client,--conf,spark.sql.adaptive.enabled=true,--py-files,${JOB_S3_PREFIX}config.py,${JOB_S3_PREFIX}${SUBMIT_JOB},s3://vllm-chunking/cord19-chunks/,s3://vllm-chunking/lancedb/]" \
        --query 'StepIds[0]' --output text)

info "Step submitted: $STEP_ID"
STEP_LOG_PREFIX="s3://$BUCKET_NAME/emr-logs/${CLUSTER_ID}/steps/${STEP_ID}/"

# ---------------------------------------------------------------------------
# Monitor: SSH live tail if key available, else S3 log polling
# ---------------------------------------------------------------------------
phase "MONITOR SPARK JOB (live)"

if [ -n "$KEY_NAME" ] && [ -f "${KEY_NAME}.pem" ] && [ -n "$MASTER_DNS" ]; then
    SSH_KEY="${KEY_NAME}.pem"
    info "SSH key found — connecting to master for live log stream."
    step "Waiting for step to start running..."

    # Wait until RUNNING
    while true; do
        STEP_STATE=$(aws emr describe-step --cluster-id "$CLUSTER_ID" --step-id "$STEP_ID" \
            --region "$AWS_REGION" --query 'Step.Status.State' --output text 2>/dev/null || echo "unknown")
        [ "$STEP_STATE" == "RUNNING" ] && break
        [ "$STEP_STATE" == "COMPLETED" ] && break
        [ "$STEP_STATE" == "FAILED" ] && error "Step failed before we could connect."
        echo "  [$(date '+%H:%M:%S')] Step state: $STEP_STATE — waiting..."
        sleep 8
    done

    if [ "$STEP_STATE" == "RUNNING" ]; then
        info "Step is RUNNING. Connecting via SSH to tail Spark logs..."
        echo "  (Press Ctrl+C to detach — cluster keeps running)"
        echo "-----------------------------------------------------------------------------"
        # Tail the YARN application log on the master node
        # EMR writes Spark driver output to: /var/log/hadoop-yarn/apps/
        set +e
        ssh -i "$SSH_KEY" -o StrictHostKeyChecking=no -o ConnectTimeout=10 \
            "hadoop@$MASTER_DNS" \
            'while true; do
                APP_ID=$(yarn application -list 2>/dev/null | grep -oP "application_\d+_\d+" | head -1)
                if [ -n "$APP_ID" ]; then
                    echo "[SSH] Tailing YARN application: $APP_ID"
                    yarn logs -applicationId "$APP_ID" -log_files stdout 2>/dev/null | tail -f
                    break
                fi
                sleep 3
            done' 2>/dev/null || true
        echo "-----------------------------------------------------------------------------"
        set -e
    fi

    # Final step state
    STEP_STATE=$(aws emr describe-step --cluster-id "$CLUSTER_ID" --step-id "$STEP_ID" \
        --region "$AWS_REGION" --query 'Step.Status.State' --output text 2>/dev/null || echo "unknown")
    info "Final step state: $STEP_STATE"

else
    # No SSH key — poll step status + S3 logs every 15s
    warn "No SSH key/pem found. Using S3 log polling (updates every ~15s)."
    step "Live logs will appear here as EMR flushes them to S3..."
    echo ""

    LAST_STEP_STATE=""
    PRINTED_LINES=0

    while true; do
        STEP_STATE=$(aws emr describe-step --cluster-id "$CLUSTER_ID" --step-id "$STEP_ID" \
            --region "$AWS_REGION" --query 'Step.Status.State' --output text 2>/dev/null || echo "unknown")

        [ "$STEP_STATE" != "$LAST_STEP_STATE" ] && echo "  [$(date '+%H:%M:%S')] Step state: $STEP_STATE"
        LAST_STEP_STATE="$STEP_STATE"

        # Try to pull latest stdout from S3
        TEMP_LOG=$(mktemp)
        set +e
        aws s3 cp "${STEP_LOG_PREFIX}stdout.gz" "$TEMP_LOG" --quiet 2>/dev/null
        if [ $? -eq 0 ]; then
            TOTAL_LINES=$(zcat "$TEMP_LOG" 2>/dev/null | wc -l)
            if [ "$TOTAL_LINES" -gt "$PRINTED_LINES" ]; then
                zcat "$TEMP_LOG" 2>/dev/null | tail -n "+$((PRINTED_LINES + 1))"
                PRINTED_LINES=$TOTAL_LINES
            fi
        fi
        rm -f "$TEMP_LOG"
        set -e

        case $STEP_STATE in
            COMPLETED) echo ""; info "Spark job completed SUCCESSFULLY!"; break ;;
            FAILED|INTERRUPTED|CANCELLED)
                echo ""; error "Spark job $STEP_STATE. Check full logs at: $STEP_LOG_PREFIX" ;;
            PENDING|RUNNING) sleep 15 ;;
            *) sleep 10 ;;
        esac
    done
fi

# ---------------------------------------------------------------------------
# Terminate cluster
# ---------------------------------------------------------------------------
phase "SHUTDOWN"

if [ "$SKIP_TERMINATION" = "true" ] || [ "$SKIP_LAUNCH" = "true" ]; then
    warn "Debug Mode: Skipping termination to keep cluster $CLUSTER_ID alive."
    info "Manual termination: aws emr terminate-clusters --cluster-ids $CLUSTER_ID"
else
    set +e
    read -t 15 -p "  Terminate cluster now? [Y/n] " TERMINATE_CHOICE 2>/dev/null || TERMINATE_CHOICE="y"
    echo ""
    set -e

    if [[ "$TERMINATE_CHOICE" =~ ^[Nn] ]]; then
        warn "Cluster $CLUSTER_ID left running (auto-terminates after 4 hours idle)."
        warn "Manual termination: aws emr terminate-clusters --cluster-ids $CLUSTER_ID"
    else
        step "Terminating cluster $CLUSTER_ID ..."
        aws emr terminate-clusters --cluster-ids "$CLUSTER_ID" --region "$AWS_REGION"
        info "Cluster termination requested."
        rm -f "$SESSION_FILE"
    fi
fi

# ---------------------------------------------------------------------------
# Check S3 output
# ---------------------------------------------------------------------------
phase "VERIFY OUTPUT"
info "Checking S3 output..."
aws s3 ls "${S3_OUTPUT_PATH/s3a:/s3:}" --recursive --human-readable 2>/dev/null \
    | awk '{print "  "$0}' || warn "No output found yet at $S3_OUTPUT_PATH"

echo ""
echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
info "DONE!"
info "  Cluster ID:    $CLUSTER_ID"
info "  S3 output:     $S3_OUTPUT_PATH"
info "  EMR logs:      $EMR_LOG_PATH${CLUSTER_ID}/steps/${STEP_ID}/"
info "  Saved to:      emr-test-cluster.txt"
echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
