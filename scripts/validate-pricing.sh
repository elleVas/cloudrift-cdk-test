#!/usr/bin/env bash
# validate-pricing.sh — Runs cloudrift WITH --live-pricing and checks the
# scanners that require per-instance-type pricing lookups via the AWS Pricing API.
# Run AFTER validate.sh (standard scanners) to get the full picture.
set -euo pipefail

CLOUDRIFT_PATH="${CLOUDRIFT_PATH:-../../cloudrift}"
REGION="${AWS_REGION:-${AWS_DEFAULT_REGION:-$(aws configure get region 2>/dev/null || echo "us-east-1")}}"
REPORT_FILE="/tmp/cloudrift-validate-pricing.json"

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  validate-pricing.sh — Live-pricing scanners (--live-pricing)"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

# --- Check cloudrift is built ---
CLOUDRIFT_MAIN="$CLOUDRIFT_PATH/apps/cli/dist/main.js"
if [ ! -f "$CLOUDRIFT_MAIN" ]; then
  echo "✗ cloudrift CLI not found at: $CLOUDRIFT_MAIN"
  echo "  Build it first: cd $CLOUDRIFT_PATH && pnpm nx build cli"
  exit 1
fi

echo "→ Using cloudrift at: $CLOUDRIFT_MAIN"
echo "→ Scanning region: $REGION"
echo "→ Using --min-age-days 0 (no grace period for test resources)"
echo "→ Using --live-pricing (per-instance-type pricing via AWS Pricing API)"
echo ""

# --- Run cloudrift ---
echo "→ Running cloudrift analyze..."
node "$CLOUDRIFT_MAIN" analyze \
  --regions "$REGION" \
  --all-services \
  --min-age-days 0 \
  --live-pricing \
  --format json \
  > "$REPORT_FILE" 2>/dev/null || true

# --- Check report exists ---
if [ ! -s "$REPORT_FILE" ]; then
  echo "✗ cloudrift produced no output. Check credentials and region."
  exit 1
fi

echo "→ Report generated. Checking findings..."
echo ""

# --- Expected kinds: scanners that REQUIRE --live-pricing ---
# These scanners need per-instance-type pricing from the AWS Pricing API.
EXPECTED_KINDS=(
  "elasticache-idle"
  "redshift-idle-cluster"
  "opensearch-idle-domain"
  "msk-idle-cluster"
  "documentdb-idle-instance"
  "neptune-idle-instance"
  "mq-idle-broker"
)

# Time-dependent live-pricing scanners (opt-in — require 7-14d)
if [ "${INCLUDE_TIME_DEPENDENT:-false}" = "true" ]; then
  EXPECTED_KINDS+=("ec2-underutilized")
  EXPECTED_KINDS+=("rds-underutilized")
fi

# WorkSpaces (opt-in)
if [ "${INCLUDE_WORKSPACES:-false}" = "true" ]; then
  EXPECTED_KINDS+=("workspaces-idle")
fi

# SageMaker (opt-in — notebook + endpoint require live pricing)
if [ "${INCLUDE_SAGEMAKER:-false}" = "true" ]; then
  EXPECTED_KINDS+=("sagemaker-notebook-idle")
  EXPECTED_KINDS+=("sagemaker-endpoint-idle")
fi

# EKS node overprovisioned (opt-in — requires live pricing + 168h metrics)
if [ "${INCLUDE_EKS:-false}" = "true" ] && [ "${INCLUDE_TIME_DEPENDENT:-false}" = "true" ]; then
  EXPECTED_KINDS+=("eks-node-overprovisioned")
fi

PASS_COUNT=0
FAIL_COUNT=0
RESULTS=()

for KIND in "${EXPECTED_KINDS[@]}"; do
  COUNT=$(cat "$REPORT_FILE" | python3 -c "
import json, sys
data = json.load(sys.stdin)
findings = data.get('findings', [])
count = sum(1 for f in findings if f.get('kind') == '$KIND')
print(count)
" 2>/dev/null || echo "0")

  if [ "$COUNT" -gt 0 ]; then
    RESULTS+=("  ✔ $KIND — found $COUNT finding(s)")
    ((PASS_COUNT++))
  else
    RESULTS+=("  ✗ $KIND — NOT FOUND")
    ((FAIL_COUNT++))
  fi
done

# --- Print results ---
echo "┌─────────────────────────────────────────────────────────────────┐"
echo "│  Live-Pricing Scanner Results (--live-pricing)                  │"
echo "├─────────────────────────────────────────────────────────────────┤"
for R in "${RESULTS[@]}"; do
  echo "│ $R"
done
echo "└─────────────────────────────────────────────────────────────────┘"
echo ""

TOTAL=$((PASS_COUNT + FAIL_COUNT))

WASTE_TOTAL=$(cat "$REPORT_FILE" | python3 -c "
import json, sys
data = json.load(sys.stdin)
print(f\"\${data.get('totalWasteMonthlyUsd', 0):.2f}\")
" 2>/dev/null || echo "?.??")

OPT_TOTAL=$(cat "$REPORT_FILE" | python3 -c "
import json, sys
data = json.load(sys.stdin)
print(f\"\${data.get('totalOptimizationMonthlyUsd', 0):.2f}\")
" 2>/dev/null || echo "?.??")

echo "  Waste total:        $WASTE_TOTAL/month  (includes standard + pricing)"
echo "  Optimization total: $OPT_TOTAL/month"
echo ""

if [ "$FAIL_COUNT" -eq 0 ]; then
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo "  ✔ ALL PASSED ($PASS_COUNT/$TOTAL live-pricing kinds detected)"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  exit 0
else
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo "  ✗ FAILED ($FAIL_COUNT/$TOTAL live-pricing kinds NOT detected)"
  echo ""
  echo "  Possible causes:"
  echo "  - CloudWatch metrics need more time (wait 5-10 min after post-deploy)"
  echo "  - Resource was not created properly (check stack outputs)"
  echo "  - AWS Pricing API connectivity issue"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  exit 1
fi
