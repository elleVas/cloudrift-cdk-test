#!/usr/bin/env bash
# concurrency-test.sh — Runs cloudrift with different CLOUDRIFT_SCAN_CONCURRENCY
# values and compares timing + findings consistency.
set -euo pipefail

CLOUDRIFT_PATH="${CLOUDRIFT_PATH:-../../cloudrift}"
CLI="$CLOUDRIFT_PATH/apps/cli/dist/main.js"
# Auto-detect region: use AWS_REGION / AWS_DEFAULT_REGION / aws configure,
# in that order. CDK uses the same resolution so this always matches where
# the stack was deployed.
REGION="${AWS_REGION:-${AWS_DEFAULT_REGION:-$(aws configure get region 2>/dev/null || echo "us-east-1")}}"
OUT_DIR="/tmp/cloudrift-concurrency-test"
CONCURRENCY_VALUES=(1 3 5 10 20)

# ─── Preflight checks ────────────────────────────────────────────────────────
if [ ! -f "$CLI" ]; then
  echo "✗ cloudrift CLI not found at: $CLI"
  echo "  Set CLOUDRIFT_PATH or build it: cd $CLOUDRIFT_PATH && pnpm nx build cli"
  exit 1
fi

# Quick credential check
aws sts get-caller-identity --region "$REGION" > /dev/null 2>&1 || {
  echo "✗ AWS credentials not available. Run 'aws sso login' or export credentials first."
  exit 1
}

ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text --region "$REGION")
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  CLOUDRIFT CONCURRENCY TEST"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  Account:  $ACCOUNT_ID"
echo "  Region:   $REGION"
echo "  CLI:      $CLI"
echo "  Values:   ${CONCURRENCY_VALUES[*]}"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

mkdir -p "$OUT_DIR"

# ─── Run tests ────────────────────────────────────────────────────────────────
declare -a TIMES=()
declare -a FINDING_COUNTS=()
declare -a ERROR_COUNTS=()

for CONC in "${CONCURRENCY_VALUES[@]}"; do
  REPORT="$OUT_DIR/report-c${CONC}.json"
  echo "→ Running with CLOUDRIFT_SCAN_CONCURRENCY=$CONC ..."

  START_TIME=$(date +%s)
  CLOUDRIFT_SCAN_CONCURRENCY=$CONC node "$CLI" analyze \
    --regions "$REGION" \
    --all-services \
    --min-age-days 0 \
    --live-pricing \
    --format json \
    > "$REPORT" 2>/dev/null || true
  END_TIME=$(date +%s)
  ELAPSED=$((END_TIME - START_TIME))

  # Count findings and errors
  if [ -s "$REPORT" ]; then
    FCOUNT=$(cat "$REPORT" | python3 -c "import json,sys; d=json.load(sys.stdin); print(len(d.get('findings',[])))")
    ECOUNT=$(cat "$REPORT" | python3 -c "import json,sys; d=json.load(sys.stdin); print(len(d.get('scanErrors',[])))")
  else
    FCOUNT="ERR"
    ECOUNT="ERR"
  fi

  TIMES+=("$ELAPSED")
  FINDING_COUNTS+=("$FCOUNT")
  ERROR_COUNTS+=("$ECOUNT")
  echo "  Done: ${ELAPSED}s | findings=$FCOUNT | errors=$ECOUNT"
  echo ""
done

# ─── Results ──────────────────────────────────────────────────────────────────
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  RISULTATI"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
printf "  %-15s %-10s %-10s %-10s\n" "Concurrency" "Time(s)" "Findings" "Errors"
printf "  %-15s %-10s %-10s %-10s\n" "───────────" "───────" "────────" "──────"

for i in "${!CONCURRENCY_VALUES[@]}"; do
  printf "  %-15s %-10s %-10s %-10s\n" \
    "${CONCURRENCY_VALUES[$i]}" "${TIMES[$i]}" "${FINDING_COUNTS[$i]}" "${ERROR_COUNTS[$i]}"
done

echo ""

# ─── Consistency check ────────────────────────────────────────────────────────
FIRST_COUNT="${FINDING_COUNTS[0]}"
ALL_SAME=true
for FC in "${FINDING_COUNTS[@]}"; do
  if [ "$FC" != "$FIRST_COUNT" ]; then
    ALL_SAME=false
    break
  fi
done

if [ "$ALL_SAME" = true ] && [ "$FIRST_COUNT" != "ERR" ] && [ "$FIRST_COUNT" != "0" ]; then
  echo "  ✔ CONSISTENCY OK — all runs returned $FIRST_COUNT findings"
elif [ "$FIRST_COUNT" = "0" ]; then
  echo "  ⚠ WARNING — 0 findings returned. Check scan errors (credentials/permissions)."
else
  echo "  ✗ INCONSISTENCY — finding counts differ across concurrency levels!"
  echo "    This may indicate a race condition or throttling issue."
fi

# ─── Speedup ──────────────────────────────────────────────────────────────────
if [ "${TIMES[0]}" -gt 0 ]; then
  echo ""
  echo "  Speedups vs concurrency=1 (${TIMES[0]}s):"
  for i in "${!CONCURRENCY_VALUES[@]}"; do
    if [ "$i" -gt 0 ] && [ "${TIMES[$i]}" -gt 0 ]; then
      SPEEDUP=$(python3 -c "import sys; print(f'{float(sys.argv[1])/float(sys.argv[2]):.1f}x')" "${TIMES[0]}" "${TIMES[$i]}" 2>/dev/null || echo "?")
      echo "    concurrency=${CONCURRENCY_VALUES[$i]}: ${TIMES[$i]}s (${SPEEDUP})"
    fi
  done
fi

echo ""

# ─── Kinds breakdown (from last run) ─────────────────────────────────────────
LAST_REPORT="$OUT_DIR/report-c${CONCURRENCY_VALUES[-1]}.json"
if [ -s "$LAST_REPORT" ]; then
  echo "  Kinds detected (from concurrency=${CONCURRENCY_VALUES[-1]} run):"
  cat "$LAST_REPORT" | python3 -c "
import json, sys
d = json.load(sys.stdin)
findings = d.get('findings', [])
from collections import Counter
kinds = Counter(f.get('kind') for f in findings)
for k, v in sorted(kinds.items()):
    print(f'    {k}: {v}')
if not kinds:
    print('    (none)')
errors = d.get('scanErrors', [])
if errors:
    print(f'\n  Scan errors ({len(errors)}):')
    for e in errors[:5]:
        print(f\"    {e.get('kind')}: {e.get('message', '')[:80]}\")
    if len(errors) > 5:
        print(f'    ... and {len(errors)-5} more')
"
fi

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  Reports saved in: $OUT_DIR/"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
