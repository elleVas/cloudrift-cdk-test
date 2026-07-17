#!/usr/bin/env bash
# post-deploy.sh — Stops EC2/RDS instances and seeds test data after CDK deploy.
# CDK cannot create resources in a "stopped" state, so we stop them here.
set -euo pipefail

STACK_NAME="${STACK_NAME:-CloudriftTestStack}"

# Auto-detect region: use AWS_REGION / AWS_DEFAULT_REGION / aws configure,
# in that order. CDK uses the same resolution so this always matches where
# the stack was deployed.
REGION="${AWS_REGION:-${AWS_DEFAULT_REGION:-$(aws configure get region 2>/dev/null || echo "us-east-1")}}"

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  post-deploy.sh — Stopping EC2 and RDS instances + seeding test data"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

# --- Get outputs from CloudFormation ---
echo ""
echo "→ Reading stack outputs from $STACK_NAME..."

EC2_INSTANCE_ID=$(aws cloudformation describe-stacks \
  --stack-name "$STACK_NAME" \
  --region "$REGION" \
  --query "Stacks[0].Outputs[?OutputKey=='StoppedInstanceId'].OutputValue" \
  --output text)

RDS_INSTANCE_ID=$(aws cloudformation describe-stacks \
  --stack-name "$STACK_NAME" \
  --region "$REGION" \
  --query "Stacks[0].Outputs[?OutputKey=='RdsInstanceId'].OutputValue" \
  --output text)

GHOST_INSTANCE_ID=$(aws cloudformation describe-stacks \
  --stack-name "$STACK_NAME" \
  --region "$REGION" \
  --query "Stacks[0].Outputs[?OutputKey=='GhostEnvInstanceId'].OutputValue" \
  --output text 2>/dev/null || echo "")

# --- Stop EC2 instance (waste: ec2-instance) ---
if [ -n "$EC2_INSTANCE_ID" ] && [ "$EC2_INSTANCE_ID" != "None" ]; then
  echo ""
  echo "→ Stopping EC2 instance: $EC2_INSTANCE_ID"
  aws ec2 stop-instances --instance-ids "$EC2_INSTANCE_ID" --region "$REGION" > /dev/null 2>&1 || true
  echo "  Waiting for instance to stop..."
  aws ec2 wait instance-stopped --instance-ids "$EC2_INSTANCE_ID" --region "$REGION" 2>/dev/null || true
  echo "  ✔ EC2 instance stopped"
else
  echo "  ⚠ No EC2 instance ID found in stack outputs"
fi

# --- Stop Ghost Environment EC2 instance (waste: environment-ghost) ---
if [ -n "$GHOST_INSTANCE_ID" ] && [ "$GHOST_INSTANCE_ID" != "None" ]; then
  echo ""
  echo "→ Stopping Ghost Environment instance: $GHOST_INSTANCE_ID"
  aws ec2 stop-instances --instance-ids "$GHOST_INSTANCE_ID" --region "$REGION" > /dev/null 2>&1 || true
  echo "  Waiting for instance to stop..."
  aws ec2 wait instance-stopped --instance-ids "$GHOST_INSTANCE_ID" --region "$REGION" 2>/dev/null || true
  echo "  ✔ Ghost env instance stopped"
else
  echo "  ⚠ No Ghost Environment instance ID found in stack outputs (may not be deployed)"
fi

# --- Stop RDS instance (waste: rds-instance) ---
if [ -n "$RDS_INSTANCE_ID" ] && [ "$RDS_INSTANCE_ID" != "None" ]; then
  echo ""
  echo "→ Stopping RDS instance: $RDS_INSTANCE_ID"
  aws rds stop-db-instance --db-instance-identifier "$RDS_INSTANCE_ID" --region "$REGION" > /dev/null 2>&1 || true
  echo "  Waiting for instance to stop (can take several minutes)..."
  aws rds wait db-instance-stopped --db-instance-identifier "$RDS_INSTANCE_ID" --region "$REGION" 2>/dev/null || true
  echo "  ✔ RDS instance stopped"
else
  echo "  ⚠ No RDS instance ID found in stack outputs"
fi

# --- Send a test message to the DLQ (for sqs-dlq-abandoned scanner) ---
echo ""
echo "→ Sending test message to abandoned DLQ..."
DLQ_URL=$(aws sqs get-queue-url \
  --queue-name "cloudrift-test-abandoned-dlq" \
  --region "$REGION" \
  --query "QueueUrl" \
  --output text 2>/dev/null || echo "")

if [ -n "$DLQ_URL" ] && [ "$DLQ_URL" != "None" ]; then
  aws sqs send-message \
    --queue-url "$DLQ_URL" \
    --message-body '{"error":"simulated failure","timestamp":"'"$(date -u +%Y-%m-%dT%H:%M:%SZ)"'","source":"cloudrift-cdk-test"}' \
    --region "$REGION" > /dev/null 2>&1 || true
  echo "  ✔ Test message sent to DLQ (will age over time for scanner detection)"
else
  echo "  ⚠ DLQ not found (ServerlessOrphans construct may not be deployed)"
fi

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  ✔ Post-deploy complete. Resources are now in 'waste' state."
echo ""
echo "  Next: wait ~5 minutes for CloudWatch to register zero-activity"
echo "  metrics, then run: npm run validate"
echo ""
echo "  NOTE: Some scanners are time-dependent and need days to trigger:"
echo "  - ec2-underutilized, rds-underutilized: 7-14d of low CPU"
echo "  - environment-ghost: 7d of all-inactive resources"
echo "  - sqs-dlq-abandoned: 14d of unconsumed messages"
echo "  - aurora-serverless-overprovisioned: 7d (168h) of low ACU"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
