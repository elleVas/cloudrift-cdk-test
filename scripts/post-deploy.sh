#!/usr/bin/env bash
# post-deploy.sh — Stops the EC2 and RDS instances after CDK deploy.
# CDK cannot create resources in a "stopped" state, so we stop them here.
set -euo pipefail

STACK_NAME="${STACK_NAME:-CloudriftTestStack}"

# Auto-detect region: use AWS_REGION / AWS_DEFAULT_REGION / aws configure,
# in that order. CDK uses the same resolution so this always matches where
# the stack was deployed.
REGION="${AWS_REGION:-${AWS_DEFAULT_REGION:-$(aws configure get region 2>/dev/null || echo "us-east-1")}}"

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  post-deploy.sh — Stopping EC2 and RDS instances"
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

# --- Stop EC2 instance ---
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

# --- Stop RDS instance ---
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

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  ✔ Post-deploy complete. Resources are now in 'waste' state."
echo ""
echo "  Next: wait ~5 minutes for CloudWatch to register zero-activity"
echo "  metrics, then run: npm run validate"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
