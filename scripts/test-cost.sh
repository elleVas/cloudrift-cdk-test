#!/usr/bin/env bash
# test-cost.sh — Test the `cloudrift cost` command.
#
# Runs `cloudrift cost` against the current account and saves the output to
# ./reports/cloudrift-cost-TIMESTAMP.json. Cost Explorer is a global AWS
# service (not region-scoped), so unlike `analyze` there is no --regions flag.
#
# Usage:
#   bash scripts/test-cost.sh
#   bash scripts/test-cost.sh --fail-on-increase 20   # pass extra flags
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
CLOUDRIFT_PATH="${CLOUDRIFT_PATH:-$PROJECT_DIR/../../cloudrift}"
CLOUDRIFT_MAIN="$CLOUDRIFT_PATH/apps/cli/dist/main.js"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
REPORTS_DIR="$PROJECT_DIR/reports"
mkdir -p "$REPORTS_DIR"

REPORT_FILE="$REPORTS_DIR/cloudrift-cost-$TIMESTAMP.json"
LOG_FILE="$REPORTS_DIR/cloudrift-cost-$TIMESTAMP.log"

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

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  cloudrift cost — Test"
echo "  Started: $(date)"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

# ═══════════════════════════════════════════════════════════════════════════
# PREFLIGHT
# ═══════════════════════════════════════════════════════════════════════════
if [ ! -f "$CLOUDRIFT_MAIN" ]; then
  fail "cloudrift CLI not found at: $CLOUDRIFT_MAIN"
  echo "  Set CLOUDRIFT_PATH or build: cd $CLOUDRIFT_PATH && pnpm nx build cli"
  exit 1
fi
ok "cloudrift CLI found: $CLOUDRIFT_MAIN"
echo ""

# ═══════════════════════════════════════════════════════════════════════════
# RUN: cloudrift cost
# ═══════════════════════════════════════════════════════════════════════════
# Cost Explorer bills $0.01 per API request — this is a real (tiny) charge,
# not a free describe/list call like every other cloudrift scanner.
log "Running: cloudrift cost --format json $*"
echo ""

# stdout (the JSON report) and stderr (warnings, e.g. failed STS account-id
# resolution) are kept separate on purpose: merging them with 2>&1 would
# corrupt the JSON file the moment any warning is printed.
set +e
node "$CLOUDRIFT_MAIN" cost --format json "$@" > "$REPORT_FILE" 2> "$LOG_FILE"
EXIT_CODE=$?
set -e

if [ -s "$LOG_FILE" ]; then
  warn "stderr output (see $LOG_FILE):"
  sed 's/^/    /' "$LOG_FILE"
fi

if [ ! -s "$REPORT_FILE" ]; then
  fail "cloudrift cost produced no output (exit code $EXIT_CODE)."
  echo "  Check credentials and that Cost Explorer is enabled for this account."
  exit 1
fi

ok "Report saved: $REPORT_FILE"
if [ "$EXIT_CODE" -eq 2 ]; then
  warn "Exit code 2 — the --fail-on-increase gate tripped (spend increase above threshold)."
elif [ "$EXIT_CODE" -ne 0 ]; then
  warn "Exit code $EXIT_CODE — command reported an error, see log above."
fi
echo ""

# ═══════════════════════════════════════════════════════════════════════════
# QUICK SUMMARY
# ═══════════════════════════════════════════════════════════════════════════
log "Quick summary:"
echo ""

python3 -c "
import json, sys

try:
    data = json.load(open('$REPORT_FILE'))
except Exception as e:
    print(f'  Could not parse JSON: {e}')
    sys.exit(0)

current = data.get('current', {})
previous = data.get('previous', {})
change_usd = data.get('changeUsd')
change_pct = data.get('changePercent')

print(f'  Account: {data.get(\"meta\", {}).get(\"accountId\", \"?\")}')
print(f'  Current  ({current.get(\"start\")} -> {current.get(\"end\")}): \${current.get(\"totalUsd\", 0):.2f}')
print(f'  Previous ({previous.get(\"start\")} -> {previous.get(\"end\")}): \${previous.get(\"totalUsd\", 0):.2f}')
if change_pct is None:
    print(f'  Change: \${change_usd:.2f} (n/a % — previous period was \$0)')
else:
    print(f'  Change: \${change_usd:.2f} ({change_pct:+.1f}%)')

by_service = data.get('byService', [])
if by_service:
    print(f'  By service (top 5 movers):')
    for svc in sorted(by_service, key=lambda s: abs(s.get('changeUsd', 0)), reverse=True)[:5]:
        pct = svc.get('changePercent')
        pct_label = 'n/a' if pct is None else f'{pct:+.1f}%'
        print(f'    - {svc.get(\"service\", \"?\")}: \${svc.get(\"currentUsd\", 0):.2f} (was \${svc.get(\"previousUsd\", 0):.2f}, {pct_label})')
" 2>/dev/null || warn "Could not parse report (may not be JSON — check file manually)"

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  ✔ Done — $(date)"
echo "  Report: $REPORT_FILE"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
