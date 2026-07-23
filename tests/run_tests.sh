#!/usr/bin/env bash
# tests/run_tests.sh — Run all local tests that don't require hardware
# Usage: ./tests/run_tests.sh [--sc-only] [--py-only]
#
# Requirements:
#   sclang (SuperCollider) — for .scd tests
#   python3 + pip packages  — for Python tests

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
SC_TIMEOUT=60   # seconds per test

GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m'

SC_ONLY=false
PY_ONLY=false
for arg in "$@"; do
  case $arg in
    --sc-only) SC_ONLY=true ;;
    --py-only) PY_ONLY=true ;;
  esac
done

echo ""
echo "=============================="
echo " LANTH0N 5YNTH — Local Tests"
echo "=============================="
echo ""

SC_PASS=0; SC_FAIL=0; PY_PASS=0; PY_FAIL=0

run_sc_test() {
  local file="$1"
  local name="$(basename "$file" .scd)"
  printf "  SC: %-30s " "$name"
  if timeout "$SC_TIMEOUT" sclang "$file" 2>&1 | grep -q "ALL TESTS PASSED"; then
    echo -e "${GREEN}PASS${NC}"
    SC_PASS=$((SC_PASS + 1))
  else
    echo -e "${RED}FAIL${NC}"
    SC_FAIL=$((SC_FAIL + 1))
  fi
}

run_py_test() {
  local file="$1"
  local name="$(basename "$file" .py)"
  printf "  PY: %-30s " "$name"
  if LANTH0N_OLED_MOCK=1 python3 "$file" 2>&1 | grep -qE "^OK|OK \("; then
    echo -e "${GREEN}PASS${NC}"
    PY_PASS=$((PY_PASS + 1))
  else
    echo -e "${RED}FAIL${NC}"
    PY_FAIL=$((PY_FAIL + 1))
  fi
}

# ── SuperCollider tests ──────────────────────────────────────────────────────
if ! $PY_ONLY; then
  if command -v sclang &>/dev/null; then
    echo "SuperCollider tests:"
    run_sc_test "$SCRIPT_DIR/test_synths.scd"
    run_sc_test "$SCRIPT_DIR/test_apc_pads.scd"
    run_sc_test "$SCRIPT_DIR/test_backtrack.scd"
    run_sc_test "$SCRIPT_DIR/test_midi.scd"
  else
    echo -e "${YELLOW}  sclang not found — skipping SC tests${NC}"
    echo "  Install SuperCollider: https://supercollider.github.io/"
  fi
fi

echo ""

# ── Python tests ─────────────────────────────────────────────────────────────
if ! $SC_ONLY; then
  echo "Python tests:"
  if python3 -c "import pythonosc" 2>/dev/null; then
    run_py_test "$SCRIPT_DIR/test_oled.py"
  else
    echo -e "${YELLOW}  python-osc not installed — run: pip3 install python-osc Pillow${NC}"
  fi
fi

echo ""
echo "=============================="
echo " Results"
echo "=============================="
echo -e " SC:  ${GREEN}${SC_PASS} passed${NC}  ${RED}${SC_FAIL} failed${NC}"
echo -e " PY:  ${GREEN}${PY_PASS} passed${NC}  ${RED}${PY_FAIL} failed${NC}"
echo ""
if [ $((SC_FAIL + PY_FAIL)) -eq 0 ]; then
  echo -e "${GREEN}ALL TESTS PASSED${NC}"
  exit 0
else
  echo -e "${RED}SOME TESTS FAILED${NC}"
  exit 1
fi
