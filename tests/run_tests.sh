#!/usr/bin/env bash
# tests/run_tests.sh — Run all local tests that don't require hardware
# Usage: ./tests/run_tests.sh
#
# Requirements:
#   python3 + packages (sounddevice, soundfile, python-rtmidi, python-osc,
#   Pillow) — see deploy/setup.sh for the full install list.

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m'

PY="${PYTHON:-python3}"

echo ""
echo "=============================="
echo " LANTH0N 5YNTH — Local Tests"
echo "=============================="
echo ""

PY_PASS=0
PY_FAIL=0

run_py_test() {
  local file="$1"
  local name="$(basename "$file" .py)"
  printf "  PY: %-30s " "$name"
  if LANTH0N_OLED_MOCK=1 LANTH0N_OFFLINE=1 "$PY" "$file" 2>&1 | grep -qE "^OK|ALL TESTS PASSED"; then
    echo -e "${GREEN}PASS${NC}"
    PY_PASS=$((PY_PASS + 1))
  else
    echo -e "${RED}FAIL${NC}"
    PY_FAIL=$((PY_FAIL + 1))
  fi
}

echo "Python tests:"
if "$PY" -c "import pythonosc" 2>/dev/null; then
  run_py_test "$SCRIPT_DIR/test_oled.py"
else
  echo -e "${YELLOW}  python-osc not installed — run: pip3 install python-osc Pillow${NC}"
fi

echo ""
echo "=============================="
echo " Results"
echo "=============================="
echo -e " PY:  ${GREEN}${PY_PASS} passed${NC}  ${RED}${PY_FAIL} failed${NC}"
echo ""
if [ "$PY_FAIL" -eq 0 ]; then
  echo -e "${GREEN}ALL TESTS PASSED${NC}"
  exit 0
else
  echo -e "${RED}SOME TESTS FAILED${NC}"
  exit 1
fi
