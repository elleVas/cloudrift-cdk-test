#!/usr/bin/env bash
# validate.sh — Runs cloudrift against the deployed test resources and
# checks that every expected resource kind is detected.
set -euo pipefail

CLOUDRIFT_PATH="${CLOUDRIFT_PATH:-../../cloudrift}"
REGION="${AWS_REGION:-us-east-1}"
REPORT_FILE="/tmp/cloudrift-validate-report.json"

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  validate.sh — Running cloudrift and checking detection"
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
echo ""

# --- Run cloudrift ---
echo "→ Running cloudrift analyze..."
node "$CLOUDRIFT_MAIN" analyze \
  --regions "$REGION" \
  --all-services \
  --min-age-days 0 \
  --format json \
  > "$REPORT_FILE" 2>/dev/null || true

# --- Check report exists ---
if [ ! -s "$REPORT_FILE" ]; then
  echo "✗ cloudrift produced no output. Check credentials and region."
  exit 1
fi

echo "→ Report generated. Checking findings..."
echo ""

# --- Expected resource kinds from our stack ---
EXPECTED_KINDS=(
  "ebs-volume"
  "elastic-ip"
  "ec2-instance"
  "ebs-idle"
  "ebs-gp2-upgrade"
  "load-balancer"
  "log-group"
  "s3-no-lifecycle"
  "lambda-underutilized"
  "dynamodb-overprovisioned"
  "eni-orphaned"
  "ebs-snapshot"
)

# NAT Gateway is optional
if [ "${INCLUDE_NAT_GATEWAY:-false}" = "true" ]; then
  EXPECTED_KINDS+=("nat-gateway")
fi

PASS_COUNT=0
FAIL_COUNT=0
RESULTS=()

for KIND in "${EXPECTED_KINDS[@]}"; do
  # Check if this kind appears in findings
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
echo "│  Detection Results                                              │"
echo "├─────────────────────────────────────────────────────────────────┤"
for R in "${RESULTS[@]}"; do
  echo "│ $R"
done
echo "└─────────────────────────────────────────────────────────────────┘"
echo ""

# --- Summary ---
TOTAL=$((PASS_COUNT + FAIL_COUNT))

# Extract totals from report
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

echo "  Waste total:        $WASTE_TOTAL/month"
echo "  Optimization total: $OPT_TOTAL/month"
echo ""

if [ "$FAIL_COUNT" -eq 0 ]; then
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo "  ✔ ALL PASSED ($PASS_COUNT/$TOTAL kinds detected)"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  exit 0
else
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo "  ✗ FAILED ($FAIL_COUNT/$TOTAL kinds NOT detected)"
  echo ""
  echo "  Possible causes:"
  echo "  - CloudWatch metrics need more time (wait 5-10 min after post-deploy)"
  echo "  - Resource was not created properly (check stack outputs)"
  echo "  - Grace period: use --min-age-days 0"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  exit 1
fi
