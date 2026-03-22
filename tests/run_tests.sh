#!/usr/bin/env bash
# ============================================================================
# run_tests.sh — BATS test runner for setup_odoo test suite
# ============================================================================
# Usage:
#   ./tests/run_tests.sh              # Run all tests
#   ./tests/run_tests.sh --verbose    # Verbose output
#   ./tests/run_tests.sh <file.bats>  # Run specific test file
# ============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BATS_DIR="$SCRIPT_DIR/bats"
RESULTS_DIR="$SCRIPT_DIR/results"

# Check for BATS
if ! command -v bats >/dev/null 2>&1; then
  echo "ERROR: bats is not installed."
  echo "  macOS:  brew install bats-core"
  echo "  Ubuntu: sudo apt install bats"
  exit 1
fi

# Create results directory
mkdir -p "$RESULTS_DIR"

# Parse arguments
BATS_ARGS=()
SPECIFIC_FILE=""
for arg in "$@"; do
  case "$arg" in
    --verbose|-v)
      BATS_ARGS+=(--verbose-run)
      ;;
    *.bats)
      SPECIFIC_FILE="$arg"
      ;;
    *)
      BATS_ARGS+=("$arg")
      ;;
  esac
done

echo "========================================"
echo "  Setup Odoo — Test Suite"
echo "========================================"
echo ""

if [[ -n "$SPECIFIC_FILE" ]]; then
  echo "Running: $SPECIFIC_FILE"
  if (( ${#BATS_ARGS[@]} > 0 )); then
    bats "${BATS_ARGS[@]}" "$BATS_DIR/$SPECIFIC_FILE"
  else
    bats "$BATS_DIR/$SPECIFIC_FILE"
  fi
else
  echo "Running all tests in $BATS_DIR/"
  echo ""
  if (( ${#BATS_ARGS[@]} > 0 )); then
    bats "${BATS_ARGS[@]}" "$BATS_DIR"/*.bats
  else
    bats "$BATS_DIR"/*.bats
  fi
fi

echo ""
echo "========================================"
echo "  All tests passed!"
echo "========================================"
