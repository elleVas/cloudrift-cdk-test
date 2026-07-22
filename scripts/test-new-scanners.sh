#!/usr/bin/env bash
# test-new-scanners.sh — Standalone test for the 5 new "passive" scanners.
#
# Creates minimal seed resources via AWS CLI, runs cloudrift targeting only
# the 5 new scanner kinds, validates findings, and cleans up.
#
# Scanners tested:
#   1. ami-unused              — AMI not referenced by any instance/LC/LT
#   2. ecr-image-untagged      — ECR image with no tags
#   3. s3-multipart-upload-abandoned — incomplete multipart upload
#   4. rds-manual-snapshot-old — manual RDS snapshot older than threshold
#   5. secretsmanager-unused   — secret never accessed (createdDate > 30d ago)
#
# Prerequisites:
#   - AWS CLI configured with sufficient permissions
#   - Docker (for ECR image push)
#   - cloudrift CLI built (CLOUDRIFT_PATH)
#
# Cost: < $0.01 for a 10-minute cycle (all resources are passive/zero-compute)
#
# Usage:
#   bash scripts/test-new-scanners.sh
#   SKIP_CLEANUP=1 bash scripts/test-new-scanners.sh   # leave resources for debugging
#   SKIP_SECRET=1 bash scripts/test-new-scanners.sh    # skip secretsmanager (needs 30d)
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
CLOUDRIFT_PATH="${CLOUDRIFT_PATH:-$PROJECT_DIR/../../cloudrift}"
CLOUDRIFT_MAIN="$CLOUDRIFT_PATH/apps/cli/dist/main.js"
REGION="${AWS_REGION:-${AWS_DEFAULT_REGION:-$(aws configure get region 2>/dev/null || echo "us-east-1")}}"
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
REPORTS_DIR="$PROJECT_DIR/reports"
mkdir -p "$REPORTS_DIR"
REPORT_FILE="$REPORTS_DIR/cloudrift-new-scanners-$TIMESTAMP.json"
PREFIX="cloudrift-test-new"

# Feature flags
SKIP_CLEANUP="${SKIP_CLEANUP:-0}"
SKIP_SECRET="${SKIP_SECRET:-0}"
SKIP_RDS_SNAPSHOT="${SKIP_RDS_SNAPSHOT:-0}"

# --- Colors ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

log()  { echo -e "${CYAN}[$(date +%H:%M:%S)]${NC} $*"; }
ok()   { echo -e "${GREEN}  ✔${NC} $*"; }
warn() { echo -e "${YELLOW}  ⚠${NC} $*"; }
fail() { echo -e "${RED}  ✗${NC} $*"; }

# --- Tracking created resources for cleanup ---
CREATED_AMI_ID=""
CREATED_SNAPSHOT_ID=""
CREATED_ECR_REPO=""
CREATED_BUCKET=""
CREATED_MULTIPART_KEY=""
CREATED_MULTIPART_UPLOAD_ID=""
CREATED_RDS_SNAPSHOT_ID=""
CREATED_SECRET_ARN=""

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  test-new-scanners.sh — Standalone Test for 5 New Scanners"
echo "  Started:  $(date)"
echo "  Region:   $REGION"
echo "  Account:  $ACCOUNT_ID"
echo "  Cleanup:  $([ "$SKIP_CLEANUP" = "1" ] && echo "DISABLED" || echo "enabled")"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

# ═══════════════════════════════════════════════════════════════════════════
# PREFLIGHT: Check cloudrift CLI
# ═══════════════════════════════════════════════════════════════════════════
if [ ! -f "$CLOUDRIFT_MAIN" ]; then
  fail "cloudrift CLI not found at: $CLOUDRIFT_MAIN"
  echo "  Set CLOUDRIFT_PATH or build: cd $CLOUDRIFT_PATH && pnpm nx build cli"
  exit 1
fi
ok "cloudrift CLI found: $CLOUDRIFT_MAIN"

# ═══════════════════════════════════════════════════════════════════════════
# CLEANUP FUNCTION (runs on EXIT — always cleans up even on failure)
# ═══════════════════════════════════════════════════════════════════════════
cleanup() {
  if [ "$SKIP_CLEANUP" = "1" ]; then
    warn "SKIP_CLEANUP=1 — leaving resources in place for debugging"
    echo ""
    echo "  Resources to clean up manually:"
    [ -n "$CREATED_AMI_ID" ] && echo "    AMI:          $CREATED_AMI_ID"
    [ -n "$CREATED_SNAPSHOT_ID" ] && echo "    EBS Snapshot: $CREATED_SNAPSHOT_ID"
    [ -n "$CREATED_ECR_REPO" ] && echo "    ECR Repo:     $CREATED_ECR_REPO"
    [ -n "$CREATED_BUCKET" ] && echo "    S3 Bucket:    $CREATED_BUCKET"
    [ -n "$CREATED_RDS_SNAPSHOT_ID" ] && echo "    RDS Snapshot: $CREATED_RDS_SNAPSHOT_ID"
    [ -n "$CREATED_SECRET_ARN" ] && echo "    Secret:       $CREATED_SECRET_ARN"
    return
  fi

  echo ""
  log "CLEANUP: Removing seed resources..."

  # AMI
  if [ -n "$CREATED_AMI_ID" ]; then
    aws ec2 deregister-image --image-id "$CREATED_AMI_ID" --region "$REGION" 2>/dev/null && \
      ok "Deregistered AMI: $CREATED_AMI_ID" || warn "Failed to deregister AMI"
  fi

  # EBS Snapshot (from AMI creation)
  if [ -n "$CREATED_SNAPSHOT_ID" ]; then
    aws ec2 delete-snapshot --snapshot-id "$CREATED_SNAPSHOT_ID" --region "$REGION" 2>/dev/null && \
      ok "Deleted snapshot: $CREATED_SNAPSHOT_ID" || warn "Failed to delete snapshot"
  fi

  # ECR repo (force delete including images)
  if [ -n "$CREATED_ECR_REPO" ]; then
    aws ecr delete-repository --repository-name "$CREATED_ECR_REPO" --force --region "$REGION" 2>/dev/null && \
      ok "Deleted ECR repo: $CREATED_ECR_REPO" || warn "Failed to delete ECR repo"
  fi

  # S3 multipart upload abort + bucket delete
  if [ -n "$CREATED_BUCKET" ]; then
    if [ -n "$CREATED_MULTIPART_UPLOAD_ID" ]; then
      aws s3api abort-multipart-upload \
        --bucket "$CREATED_BUCKET" \
        --key "$CREATED_MULTIPART_KEY" \
        --upload-id "$CREATED_MULTIPART_UPLOAD_ID" \
        --region "$REGION" 2>/dev/null || true
    fi
    aws s3 rb "s3://$CREATED_BUCKET" --force --region "$REGION" 2>/dev/null && \
      ok "Deleted S3 bucket: $CREATED_BUCKET" || warn "Failed to delete bucket"
  fi

  # RDS manual snapshot
  if [ -n "$CREATED_RDS_SNAPSHOT_ID" ]; then
    aws rds delete-db-snapshot --db-snapshot-identifier "$CREATED_RDS_SNAPSHOT_ID" --region "$REGION" 2>/dev/null && \
      ok "Deleted RDS snapshot: $CREATED_RDS_SNAPSHOT_ID" || warn "Failed to delete RDS snapshot"
  fi

  # Secrets Manager secret (force delete, no recovery window)
  if [ -n "$CREATED_SECRET_ARN" ]; then
    aws secretsmanager delete-secret \
      --secret-id "$CREATED_SECRET_ARN" \
      --force-delete-without-recovery \
      --region "$REGION" 2>/dev/null && \
      ok "Deleted secret: $CREATED_SECRET_ARN" || warn "Failed to delete secret"
  fi

  ok "Cleanup complete"
}

trap cleanup EXIT

# ═══════════════════════════════════════════════════════════════════════════
# SEED 1: ami-unused — Register an AMI not referenced by any instance/LC/LT
# ═══════════════════════════════════════════════════════════════════════════
log "SEED 1/5: Creating unused AMI..."

# Create a minimal 1GB EBS volume, snapshot it, then register as AMI
SEED_VOLUME_ID=$(aws ec2 create-volume \
  --availability-zone "${REGION}a" \
  --size 1 \
  --volume-type gp3 \
  --tag-specifications "ResourceType=volume,Tags=[{Key=Name,Value=$PREFIX-ami-seed}]" \
  --region "$REGION" \
  --query "VolumeId" --output text)

# Wait for volume to be available
aws ec2 wait volume-available --volume-ids "$SEED_VOLUME_ID" --region "$REGION"

# Snapshot the volume
CREATED_SNAPSHOT_ID=$(aws ec2 create-snapshot \
  --volume-id "$SEED_VOLUME_ID" \
  --description "$PREFIX unused AMI test" \
  --tag-specifications "ResourceType=snapshot,Tags=[{Key=Name,Value=$PREFIX-ami-seed}]" \
  --region "$REGION" \
  --query "SnapshotId" --output text)

# Wait for snapshot
aws ec2 wait snapshot-completed --snapshot-ids "$CREATED_SNAPSHOT_ID" --region "$REGION"

# Delete the temp volume (no longer needed)
aws ec2 delete-volume --volume-id "$SEED_VOLUME_ID" --region "$REGION" 2>/dev/null || true

# Register AMI from snapshot
CREATED_AMI_ID=$(aws ec2 register-image \
  --name "$PREFIX-unused-ami-$TIMESTAMP" \
  --description "Cloudrift test: unused AMI (not referenced by any instance)" \
  --architecture x86_64 \
  --root-device-name /dev/xvda \
  --block-device-mappings "[{\"DeviceName\":\"/dev/xvda\",\"Ebs\":{\"SnapshotId\":\"$CREATED_SNAPSHOT_ID\",\"VolumeSize\":1,\"VolumeType\":\"gp3\",\"DeleteOnTermination\":true}}]" \
  --virtualization-type hvm \
  --ena-support \
  --region "$REGION" \
  --query "ImageId" --output text)

ok "AMI created: $CREATED_AMI_ID (unused, not referenced anywhere)"
echo ""

# ═══════════════════════════════════════════════════════════════════════════
# SEED 2: ecr-image-untagged — Push two images, then move the tag to the
#          second one. The first image loses its tag and becomes "untagged".
# ═══════════════════════════════════════════════════════════════════════════
log "SEED 2/5: Creating ECR repo with untagged image..."

CREATED_ECR_REPO="$PREFIX-untagged-$TIMESTAMP"

aws ecr create-repository \
  --repository-name "$CREATED_ECR_REPO" \
  --image-tag-mutability MUTABLE \
  --region "$REGION" > /dev/null

ECR_URI="$ACCOUNT_ID.dkr.ecr.$REGION.amazonaws.com/$CREATED_ECR_REPO"

# Login to ECR
aws ecr get-login-password --region "$REGION" | \
  docker login --username AWS --password-stdin "$ACCOUNT_ID.dkr.ecr.$REGION.amazonaws.com" 2>/dev/null

# Build and push image A with tag "latest"
TMPDIR_A=$(mktemp -d)
echo "FROM scratch" > "$TMPDIR_A/Dockerfile"
echo "COPY dummy /dummy" >> "$TMPDIR_A/Dockerfile"
echo "image-a" > "$TMPDIR_A/dummy"
docker build -t "$ECR_URI:latest" "$TMPDIR_A" --platform linux/amd64 2>/dev/null
docker push "$ECR_URI:latest" 2>/dev/null
rm -rf "$TMPDIR_A"

# Build and push image B (different content = different digest) with SAME tag "latest"
# This steals the tag from image A, leaving A untagged.
TMPDIR_B=$(mktemp -d)
echo "FROM scratch" > "$TMPDIR_B/Dockerfile"
echo "COPY dummy /dummy" >> "$TMPDIR_B/Dockerfile"
echo "image-b-$(date +%s)" > "$TMPDIR_B/dummy"
docker build -t "$ECR_URI:latest" "$TMPDIR_B" --platform linux/amd64 2>/dev/null
docker push "$ECR_URI:latest" 2>/dev/null
rm -rf "$TMPDIR_B"

# Verify we have an untagged image
UNTAGGED_COUNT=$(aws ecr describe-images \
  --repository-name "$CREATED_ECR_REPO" \
  --filter "tagStatus=UNTAGGED" \
  --region "$REGION" \
  --query "length(imageDetails)" --output text 2>/dev/null || echo "0")

if [ "$UNTAGGED_COUNT" -gt 0 ]; then
  ok "ECR repo created: $CREATED_ECR_REPO ($UNTAGGED_COUNT untagged image(s))"
else
  warn "ECR repo created but no untagged images detected — scanner may not trigger"
fi
echo ""

# ═══════════════════════════════════════════════════════════════════════════
# SEED 3: s3-multipart-upload-abandoned — Start a multipart upload, never complete it
# ═══════════════════════════════════════════════════════════════════════════
log "SEED 3/5: Creating S3 bucket with abandoned multipart upload..."

BUCKET_TS=$(echo "$TIMESTAMP" | tr '_' '-')
CREATED_BUCKET="$PREFIX-multipart-$ACCOUNT_ID-$BUCKET_TS"
CREATED_MULTIPART_KEY="abandoned-upload/test-file.bin"

aws s3 mb "s3://$CREATED_BUCKET" --region "$REGION" > /dev/null

# Start a multipart upload — never complete or abort it
CREATED_MULTIPART_UPLOAD_ID=$(aws s3api create-multipart-upload \
  --bucket "$CREATED_BUCKET" \
  --key "$CREATED_MULTIPART_KEY" \
  --region "$REGION" \
  --query "UploadId" --output text)

ok "S3 bucket: $CREATED_BUCKET (multipart upload started, never completed)"
echo ""

# ═══════════════════════════════════════════════════════════════════════════
# SEED 4: rds-manual-snapshot-old — Create a manual snapshot (appears old via --min-age-days 0)
# ═══════════════════════════════════════════════════════════════════════════
if [ "$SKIP_RDS_SNAPSHOT" = "1" ]; then
  warn "SEED 4/5: SKIPPED (SKIP_RDS_SNAPSHOT=1)"
  echo ""
else
  log "SEED 4/5: Creating RDS manual snapshot..."

  CREATED_RDS_SNAPSHOT_ID="$PREFIX-old-snapshot-$TIMESTAMP"
  RDS_SNAPSHOT_CREATED=0
  TEMP_RDS_CREATED=0
  TEMP_RDS_ID=""
  TEMP_RDS_SUBNET_GROUP=""

  # Try to use existing stack RDS instance (if deployed)
  EXISTING_RDS_ID=$(aws cloudformation describe-stacks \
    --stack-name CloudriftTestStack \
    --region "$REGION" \
    --query "Stacks[0].Outputs[?OutputKey=='RdsInstanceId'].OutputValue" \
    --output text 2>/dev/null || echo "")

  if [ -n "$EXISTING_RDS_ID" ] && [ "$EXISTING_RDS_ID" != "None" ]; then
    log "  Using existing RDS instance from CDK stack: $EXISTING_RDS_ID"
    aws rds create-db-snapshot \
      --db-instance-identifier "$EXISTING_RDS_ID" \
      --db-snapshot-identifier "$CREATED_RDS_SNAPSHOT_ID" \
      --region "$REGION" > /dev/null 2>&1 && RDS_SNAPSHOT_CREATED=1

    if [ "$RDS_SNAPSHOT_CREATED" = "1" ]; then
      log "  Waiting for snapshot to become available..."
      aws rds wait db-snapshot-available \
        --db-snapshot-identifier "$CREATED_RDS_SNAPSHOT_ID" \
        --region "$REGION" 2>/dev/null
    fi
  else
    # No CDK stack deployed — look for ANY available RDS instance in the account
    ANY_RDS_ID=$(aws rds describe-db-instances \
      --region "$REGION" \
      --query "DBInstances[?DBInstanceStatus=='available'] | [0].DBInstanceIdentifier" \
      --output text 2>/dev/null || echo "None")

    if [ -n "$ANY_RDS_ID" ] && [ "$ANY_RDS_ID" != "None" ]; then
      log "  Using existing RDS instance: $ANY_RDS_ID"
      aws rds create-db-snapshot \
        --db-instance-identifier "$ANY_RDS_ID" \
        --db-snapshot-identifier "$CREATED_RDS_SNAPSHOT_ID" \
        --region "$REGION" > /dev/null 2>&1 && RDS_SNAPSHOT_CREATED=1

      if [ "$RDS_SNAPSHOT_CREATED" = "1" ]; then
        log "  Waiting for snapshot to become available..."
        aws rds wait db-snapshot-available \
          --db-snapshot-identifier "$CREATED_RDS_SNAPSHOT_ID" \
          --region "$REGION" 2>/dev/null
      fi
    else
      # Last resort: create a temporary RDS instance with explicit subnet group
      log "  No RDS instances found — creating a temporary one (~5-7 min)..."
      TEMP_RDS_ID="$PREFIX-temp-rds"

      # Find subnets in at least 2 AZs for the DB subnet group
      DEFAULT_VPC_ID=$(aws ec2 describe-vpcs \
        --filters "Name=isDefault,Values=true" \
        --region "$REGION" \
        --query "Vpcs[0].VpcId" --output text 2>/dev/null || echo "None")

      if [ "$DEFAULT_VPC_ID" = "None" ] || [ -z "$DEFAULT_VPC_ID" ]; then
        # No default VPC — use any VPC with subnets in 2+ AZs
        DEFAULT_VPC_ID=$(aws ec2 describe-vpcs \
          --region "$REGION" \
          --query "Vpcs[0].VpcId" --output text 2>/dev/null || echo "None")
      fi

      if [ "$DEFAULT_VPC_ID" != "None" ] && [ -n "$DEFAULT_VPC_ID" ]; then
        SUBNET_IDS=$(aws ec2 describe-subnets \
          --filters "Name=vpc-id,Values=$DEFAULT_VPC_ID" \
          --region "$REGION" \
          --query "Subnets[*].SubnetId" --output text 2>/dev/null || echo "")

        # Need at least 2 subnets for a DB subnet group
        SUBNET_COUNT=$(echo "$SUBNET_IDS" | wc -w | tr -d ' ')
        if [ "$SUBNET_COUNT" -ge 2 ]; then
          TEMP_RDS_SUBNET_GROUP="$PREFIX-subnet-group"
          # Convert space-separated to comma-separated for the CLI
          SUBNET_LIST=$(echo "$SUBNET_IDS" | tr '\t' ' ' | sed 's/ /,/g' | sed 's/,$//')

          aws rds create-db-subnet-group \
            --db-subnet-group-name "$TEMP_RDS_SUBNET_GROUP" \
            --db-subnet-group-description "Temp subnet group for cloudrift scanner test" \
            --subnet-ids $SUBNET_IDS \
            --region "$REGION" > /dev/null 2>&1

          aws rds create-db-instance \
            --db-instance-identifier "$TEMP_RDS_ID" \
            --db-instance-class db.t3.micro \
            --engine postgres \
            --master-username postgres \
            --manage-master-user-password \
            --allocated-storage 20 \
            --storage-type gp3 \
            --no-multi-az \
            --db-subnet-group-name "$TEMP_RDS_SUBNET_GROUP" \
            --no-publicly-accessible \
            --region "$REGION" > /dev/null 2>&1 && TEMP_RDS_CREATED=1

          if [ "$TEMP_RDS_CREATED" = "1" ]; then
            log "  Waiting for temp RDS instance to be available (~5-7 min)..."
            aws rds wait db-instance-available \
              --db-instance-identifier "$TEMP_RDS_ID" \
              --region "$REGION" 2>/dev/null

            aws rds create-db-snapshot \
              --db-instance-identifier "$TEMP_RDS_ID" \
              --db-snapshot-identifier "$CREATED_RDS_SNAPSHOT_ID" \
              --region "$REGION" > /dev/null 2>&1 && RDS_SNAPSHOT_CREATED=1

            if [ "$RDS_SNAPSHOT_CREATED" = "1" ]; then
              log "  Waiting for snapshot..."
              aws rds wait db-snapshot-available \
                --db-snapshot-identifier "$CREATED_RDS_SNAPSHOT_ID" \
                --region "$REGION" 2>/dev/null
            fi

            # Delete temp instance immediately (skip final snapshot)
            log "  Deleting temp RDS instance..."
            aws rds delete-db-instance \
              --db-instance-identifier "$TEMP_RDS_ID" \
              --skip-final-snapshot \
              --delete-automated-backups \
              --region "$REGION" > /dev/null 2>&1 || true

            # Wait for deletion before removing subnet group
            aws rds wait db-instance-deleted \
              --db-instance-identifier "$TEMP_RDS_ID" \
              --region "$REGION" 2>/dev/null || true

            # Cleanup subnet group
            if [ -n "$TEMP_RDS_SUBNET_GROUP" ]; then
              aws rds delete-db-subnet-group \
                --db-subnet-group-name "$TEMP_RDS_SUBNET_GROUP" \
                --region "$REGION" 2>/dev/null || true
            fi
          fi
        fi
      fi
    fi
  fi

  if [ "$RDS_SNAPSHOT_CREATED" = "1" ]; then
    ok "RDS manual snapshot: $CREATED_RDS_SNAPSHOT_ID"
  else
    warn "SEED 4/5: Could not create RDS snapshot (no VPC with 2+ subnets or create failed)."
    warn "  Deploy the CDK stack first, or use SKIP_RDS_SNAPSHOT=1 to suppress this."
    CREATED_RDS_SNAPSHOT_ID=""
  fi
  echo ""
fi

# ═══════════════════════════════════════════════════════════════════════════
# SEED 5: secretsmanager-unused — Secret with createdDate > 30 days ago
# ═══════════════════════════════════════════════════════════════════════════
if [ "$SKIP_SECRET" = "1" ]; then
  warn "SEED 5/5: SKIPPED (SKIP_SECRET=1)"
  warn "  secretsmanager-unused needs createdDate > 30d ago to trigger."
  warn "  Create the secret now and re-run in 30+ days, or use an existing old secret."
  echo ""
else
  log "SEED 5/5: Creating Secrets Manager secret..."
  log "  NOTE: This secret will only trigger the scanner if --min-age-days 0 is used"
  log "  OR if you wait 30+ days. The scanner falls back to createdDate when"
  log "  LastAccessedDate is undefined (never accessed)."

  SECRET_NAME="$PREFIX-unused-secret-$TIMESTAMP"
  CREATED_SECRET_ARN=$(aws secretsmanager create-secret \
    --name "$SECRET_NAME" \
    --description "Cloudrift test: secret that is never accessed" \
    --secret-string '{"username":"test","password":"never-read"}' \
    --region "$REGION" \
    --query "ARN" --output text)

  ok "Secret created: $SECRET_NAME"
  ok "  ARN: $CREATED_SECRET_ARN"
  ok "  LastAccessedDate will be undefined (never retrieved)"
  echo ""
fi

# ═══════════════════════════════════════════════════════════════════════════
# SCAN: Run cloudrift targeting only the 5 new scanner kinds
# ═══════════════════════════════════════════════════════════════════════════
log "SCAN: Running cloudrift analyze (--min-age-days 0, all services)..."
echo ""

node "$CLOUDRIFT_MAIN" analyze \
  --regions "$REGION" \
  --all-services \
  --min-age-days 0 \
  --format json \
  > "$REPORT_FILE" 2>/dev/null || true

if [ ! -s "$REPORT_FILE" ]; then
  fail "cloudrift produced no output. Check credentials and region."
  exit 1
fi

ok "Report generated: $REPORT_FILE"
echo ""

# ═══════════════════════════════════════════════════════════════════════════
# VALIDATE: Check that each of the 5 new kinds appears in findings
# ═══════════════════════════════════════════════════════════════════════════
log "VALIDATE: Checking findings for new scanner kinds..."
echo ""

EXPECTED_KINDS=(
  "ami-unused"
  "ecr-image-untagged"
  "s3-multipart-upload-abandoned"
)

# Only expect rds-manual-snapshot-old if we actually created the snapshot
if [ -n "$CREATED_RDS_SNAPSHOT_ID" ]; then
  EXPECTED_KINDS+=("rds-manual-snapshot-old")
elif [ "$SKIP_RDS_SNAPSHOT" != "1" ]; then
  warn "rds-manual-snapshot-old: excluded from validation (snapshot creation failed)"
fi

# Only expect secretsmanager-unused if we seeded it AND min-age-days=0 can catch it
# (depends on how the scanner handles brand-new secrets — createdDate < 30d → not waste)
if [ "$SKIP_SECRET" != "1" ]; then
  EXPECTED_KINDS+=("secretsmanager-unused")
fi

PASS_COUNT=0
FAIL_COUNT=0
RESULTS=()

for KIND in "${EXPECTED_KINDS[@]}"; do
  COUNT=$(python3 -c "
import json, sys
data = json.load(open('$REPORT_FILE'))
findings = data.get('findings', [])
count = sum(1 for f in findings if f.get('kind') == '$KIND')
print(count)
" 2>/dev/null || echo "0")

  if [ "$COUNT" -gt 0 ]; then
    RESULTS+=("  ✔ $KIND — found $COUNT finding(s)")
    ((PASS_COUNT++)) || true
  else
    RESULTS+=("  ✗ $KIND — NOT FOUND")
    ((FAIL_COUNT++)) || true
  fi
done

# --- Print results ---
echo "┌─────────────────────────────────────────────────────────────────┐"
echo "│  New Scanner Results                                            │"
echo "├─────────────────────────────────────────────────────────────────┤"
for R in "${RESULTS[@]}"; do
  echo "│ $R"
done
echo "└─────────────────────────────────────────────────────────────────┘"
echo ""

TOTAL=$((PASS_COUNT + FAIL_COUNT))

# --- Summary ---
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

if [ "$FAIL_COUNT" -eq 0 ]; then
  echo -e "  ${GREEN}✔ ALL PASSED${NC} ($PASS_COUNT/$TOTAL new scanner kinds detected)"
else
  echo -e "  ${RED}✗ PARTIAL${NC} ($PASS_COUNT/$TOTAL passed, $FAIL_COUNT failed)"
  echo ""
  echo "  Notes on expected failures:"
  echo "  - secretsmanager-unused: only triggers if createdDate > 30 days ago."
  echo "    A brand-new secret (created just now) will NOT be flagged because"
  echo "    the policy gives a 30-day grace period on createdDate when"
  echo "    LastAccessedDate is undefined."
  echo "    → Create the secret now, re-run in 30 days. Or use SKIP_SECRET=1."
  echo "  - rds-manual-snapshot-old: if your policy requires a minimum age"
  echo "    beyond 0 days, the snapshot won't trigger immediately."
fi

echo ""
echo "  Report: $REPORT_FILE"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

# ═══════════════════════════════════════════════════════════════════════════
# DESTROY: Explicit cleanup of all seed resources
# ═══════════════════════════════════════════════════════════════════════════
echo ""
log "DESTROY: Cleaning up all seed resources..."

# Disable the EXIT trap — we're doing cleanup explicitly now
trap - EXIT

cleanup

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  ✔ Test cycle complete — $(date)"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

# Exit with failure if any scanner was not detected
if [ "$FAIL_COUNT" -gt 0 ]; then
  exit 1
fi
