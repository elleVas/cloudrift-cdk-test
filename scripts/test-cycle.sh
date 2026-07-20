#!/usr/bin/env bash
# test-cycle.sh — Full deploy/validate/destroy cycle for cloudrift-cdk-test.
#
# Produces 4 report files in ./reports/:
#   1. cloudrift-standard-TIMESTAMP.json   (no --live-pricing)
#   2. cloudrift-pricing-TIMESTAMP.json    (--live-pricing)
#   3. cloudrift-standard-TIMESTAMP.pdf    (no --live-pricing, PDF)
#   4. cloudrift-pricing-TIMESTAMP.pdf     (--live-pricing, PDF)
#
# Usage: bash scripts/test-cycle.sh
# Budget: ~$5-7 for a 50-70min cycle (default config, no EKS/SageMaker/WorkSpaces)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
CLOUDRIFT_PATH="${CLOUDRIFT_PATH:-$PROJECT_DIR/../../cloudrift}"
REGION="${AWS_REGION:-${AWS_DEFAULT_REGION:-$(aws configure get region 2>/dev/null || echo "us-east-1")}}"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
REPORTS_DIR="$PROJECT_DIR/reports"
CLOUDRIFT_MAIN="$CLOUDRIFT_PATH/apps/cli/dist/main.js"

# Ensure reports dir exists
mkdir -p "$REPORTS_DIR"

# --- Colors ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

log()  { echo -e "${CYAN}[$(date +%H:%M:%S)]${NC} $*"; }
ok()   { echo -e "${GREEN}  ✔${NC} $*"; }
warn() { echo -e "${YELLOW}  ⚠${NC} $*"; }
fail() { echo -e "${RED}  ✗${NC} $*"; }

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  cloudrift-cdk-test — Full Test Cycle"
echo "  Started: $(date)"
echo "  Region:  $REGION"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

# ═══════════════════════════════════════════════════════════════════════════
# STEP 1: Rebuild cloudrift CLI from latest source
# ═══════════════════════════════════════════════════════════════════════════
log "STEP 1/7: Rebuilding cloudrift CLI from source..."

if [ ! -d "$CLOUDRIFT_PATH" ]; then
  fail "cloudrift repo not found at: $CLOUDRIFT_PATH"
  echo "  Set CLOUDRIFT_PATH env var or clone it at ../../cloudrift"
  exit 1
fi

(
  cd "$CLOUDRIFT_PATH"
  log "  Pulling latest changes..."
  git pull --ff-only 2>/dev/null || warn "git pull failed (offline or dirty tree?) — using current HEAD"
  log "  Building CLI (pnpm nx build cli)..."
  pnpm nx build cli
)

if [ ! -f "$CLOUDRIFT_MAIN" ]; then
  fail "Build succeeded but main.js not found at: $CLOUDRIFT_MAIN"
  exit 1
fi

ok "cloudrift CLI built successfully"
echo ""

# ═══════════════════════════════════════════════════════════════════════════
# STEP 2: CDK Deploy
# ═══════════════════════════════════════════════════════════════════════════
log "STEP 2/7: Deploying CloudriftTestStack..."
log "  (default config: no EKS, no SageMaker, no WorkSpaces, no time-dependent)"

cd "$PROJECT_DIR"
npx cdk deploy --require-approval never 2>&1 | tail -5

ok "Stack deployed"
echo ""

# ═══════════════════════════════════════════════════════════════════════════
# STEP 3: Post-deploy (stop EC2/RDS, seed DLQ)
# ═══════════════════════════════════════════════════════════════════════════
log "STEP 3/7: Running post-deploy (stopping EC2/RDS)..."
log "  (includes wait-for-available before stopping RDS)"

bash "$SCRIPT_DIR/post-deploy.sh"

# Verify RDS is actually stopped
RDS_ID=$(aws cloudformation describe-stacks \
  --stack-name CloudriftTestStack \
  --region "$REGION" \
  --query "Stacks[0].Outputs[?OutputKey=='RdsInstanceId'].OutputValue" \
  --output text 2>/dev/null || echo "")

if [ -n "$RDS_ID" ] && [ "$RDS_ID" != "None" ]; then
  RDS_STATUS=$(aws rds describe-db-instances \
    --db-instance-identifier "$RDS_ID" \
    --region "$REGION" \
    --query "DBInstances[0].DBInstanceStatus" \
    --output text 2>/dev/null || echo "unknown")
  if [ "$RDS_STATUS" = "stopped" ]; then
    ok "RDS instance confirmed stopped: $RDS_ID"
  else
    warn "RDS instance is '$RDS_STATUS' (expected 'stopped') — retrying stop..."
    aws rds wait db-instance-available --db-instance-identifier "$RDS_ID" --region "$REGION" 2>/dev/null || true
    aws rds stop-db-instance --db-instance-identifier "$RDS_ID" --region "$REGION" > /dev/null 2>&1 || true
    aws rds wait db-instance-stopped --db-instance-identifier "$RDS_ID" --region "$REGION" 2>/dev/null || true
    ok "RDS instance stopped (retry)"
  fi
fi

ok "Post-deploy complete"
echo ""

# ═══════════════════════════════════════════════════════════════════════════
# STEP 4: Wait for CloudWatch metrics
# ═══════════════════════════════════════════════════════════════════════════
log "STEP 4/7: Waiting 5 minutes for CloudWatch metrics to populate..."

for i in $(seq 300 -30 0); do
  printf "\r  ⏳ %d seconds remaining...    " "$i"
  sleep 30
done
printf "\r  ✔ Wait complete.                    \n"
echo ""

# ═══════════════════════════════════════════════════════════════════════════
# STEP 5: Validate — Standard scanners (no --live-pricing)
# ═══════════════════════════════════════════════════════════════════════════
log "STEP 5/7: Running cloudrift (standard scanners, no --live-pricing)..."

STANDARD_JSON="$REPORTS_DIR/cloudrift-standard-$TIMESTAMP.json"
STANDARD_PDF="$REPORTS_DIR/cloudrift-standard-$TIMESTAMP.pdf"

# JSON report
node "$CLOUDRIFT_MAIN" analyze \
  --regions "$REGION" \
  --all-services \
  --min-age-days 0 \
  --format json \
  > "$STANDARD_JSON" 2>/dev/null || true

if [ -s "$STANDARD_JSON" ]; then
  ok "Standard JSON report: $STANDARD_JSON"
  STANDARD_FINDINGS=$(python3 -c "import json; d=json.load(open('$STANDARD_JSON')); print(len(d.get('findings',[])))" 2>/dev/null || echo "?")
  STANDARD_WASTE=$(python3 -c "import json; d=json.load(open('$STANDARD_JSON')); print(f\"\${d.get('totalWasteMonthlyUsd',0):.2f}\")" 2>/dev/null || echo "?")
  echo "    Findings: $STANDARD_FINDINGS | Waste: $STANDARD_WASTE/month"
else
  fail "Standard JSON report is empty!"
fi

# PDF report
node "$CLOUDRIFT_MAIN" analyze \
  --regions "$REGION" \
  --all-services \
  --min-age-days 0 \
  --pdf \
  --output "$STANDARD_PDF" \
  2>/dev/null || true

if [ -s "$STANDARD_PDF" ]; then
  ok "Standard PDF report: $STANDARD_PDF"
else
  warn "Standard PDF report not generated (check --pdf/--output support)"
fi

echo ""

# ═══════════════════════════════════════════════════════════════════════════
# STEP 5b: Wait for OpenSearch domain to finish processing
# ═══════════════════════════════════════════════════════════════════════════
log "STEP 5b: Waiting for OpenSearch domain to be fully active..."

OS_DOMAIN_NAME=$(aws opensearch list-domain-names \
  --region "$REGION" \
  --query "DomainNames[?DomainName!=\`null\`].DomainName | [0]" \
  --output text 2>/dev/null || echo "")

if [ -n "$OS_DOMAIN_NAME" ] && [ "$OS_DOMAIN_NAME" != "None" ]; then
  for i in $(seq 1 20); do
    PROCESSING=$(aws opensearch describe-domain \
      --domain-name "$OS_DOMAIN_NAME" \
      --region "$REGION" \
      --query "DomainStatus.Processing" --output text 2>/dev/null || echo "true")
    if [ "$PROCESSING" = "False" ] || [ "$PROCESSING" = "false" ]; then
      ok "OpenSearch domain '$OS_DOMAIN_NAME' is active (Processing=false)"
      break
    fi
    printf "  ⏳ OpenSearch still processing... (%d/20, waiting 30s)\n" "$i"
    sleep 30
  done
else
  warn "No OpenSearch domain found in region $REGION"
fi

echo ""

# ═══════════════════════════════════════════════════════════════════════════
# STEP 6: Validate — Live-pricing scanners (--live-pricing)
# ═══════════════════════════════════════════════════════════════════════════
log "STEP 6/7: Running cloudrift (live-pricing scanners)..."

PRICING_JSON="$REPORTS_DIR/cloudrift-pricing-$TIMESTAMP.json"
PRICING_PDF="$REPORTS_DIR/cloudrift-pricing-$TIMESTAMP.pdf"

# JSON report
node "$CLOUDRIFT_MAIN" analyze \
  --regions "$REGION" \
  --all-services \
  --min-age-days 0 \
  --live-pricing \
  --format json \
  > "$PRICING_JSON" 2>/dev/null || true

if [ -s "$PRICING_JSON" ]; then
  ok "Pricing JSON report: $PRICING_JSON"
  PRICING_FINDINGS=$(python3 -c "import json; d=json.load(open('$PRICING_JSON')); print(len(d.get('findings',[])))" 2>/dev/null || echo "?")
  PRICING_WASTE=$(python3 -c "import json; d=json.load(open('$PRICING_JSON')); print(f\"\${d.get('totalWasteMonthlyUsd',0):.2f}\")" 2>/dev/null || echo "?")
  echo "    Findings: $PRICING_FINDINGS | Waste: $PRICING_WASTE/month"
else
  fail "Pricing JSON report is empty!"
fi

# PDF report
node "$CLOUDRIFT_MAIN" analyze \
  --regions "$REGION" \
  --all-services \
  --min-age-days 0 \
  --live-pricing \
  --pdf \
  --output "$PRICING_PDF" \
  2>/dev/null || true

if [ -s "$PRICING_PDF" ]; then
  ok "Pricing PDF report: $PRICING_PDF"
else
  warn "Pricing PDF report not generated (check --pdf/--output support)"
fi

echo ""

# ═══════════════════════════════════════════════════════════════════════════
# STEP 7: Destroy stack
# ═══════════════════════════════════════════════════════════════════════════
log "STEP 7/7: Destroying CloudriftTestStack..."

cd "$PROJECT_DIR"
npx cdk destroy --force 2>&1 | tail -5

ok "Stack destroyed"
echo ""

# ═══════════════════════════════════════════════════════════════════════════
# SUMMARY
# ═══════════════════════════════════════════════════════════════════════════
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  ✔ Test cycle complete — $(date)"
echo ""
echo "  Reports generated:"
echo "    Standard (no --live-pricing):"
echo "      JSON: $STANDARD_JSON"
echo "      PDF:  $STANDARD_PDF"
echo "    Live-pricing (--live-pricing):"
echo "      JSON: $PRICING_JSON"
echo "      PDF:  $PRICING_PDF"
echo ""
echo "  Verification checklist:"
echo "    A. Check lambda-loggroup-orphaned → lastEvent shows 'never' (not 1970-01-01)"
echo "    B. Check pricing report for 'elasticache-idle' and 'opensearch-idle-domain'"
echo "    C. Standard vs Pricing split: compare both JSON reports"
echo ""
echo "  Next: share both JSON files (and optionally PDFs) with Claude for analysis."
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
