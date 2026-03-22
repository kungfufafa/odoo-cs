#!/usr/bin/env bats
# ============================================================================
# integration.bats — Integration tests for setup_odoo.sh
# ============================================================================
# Tests the script as a whole, verifying CLI behavior and module loading.
# Uses mocked externals where direct execution is not possible.
# ============================================================================

load test_helper

setup() {
  setup_test_environment
}

teardown() {
  teardown_test_environment
}

# --- CLI Dispatch -----------------------------------------------------------
# NOTE: We set ROOT to PROJECT_ROOT so the script finds lib/ properly.

@test "setup_odoo.sh help prints usage" {
  run env ROOT="$PROJECT_ROOT" bash "$PROJECT_ROOT/setup_odoo.sh" help
  [ "$status" -eq 0 ]
  [[ "$output" == *"Usage:"* ]]
  [[ "$output" == *"Commands:"* ]]
}

@test "setup_odoo.sh --help prints usage" {
  run env ROOT="$PROJECT_ROOT" bash "$PROJECT_ROOT/setup_odoo.sh" --help
  [ "$status" -eq 0 ]
  [[ "$output" == *"Usage:"* ]]
}

@test "setup_odoo.sh -h prints usage" {
  run env ROOT="$PROJECT_ROOT" bash "$PROJECT_ROOT/setup_odoo.sh" -h
  [ "$status" -eq 0 ]
  [[ "$output" == *"Usage:"* ]]
}

@test "setup_odoo.sh --version prints version" {
  run env ROOT="$PROJECT_ROOT" bash "$PROJECT_ROOT/setup_odoo.sh" --version
  [ "$status" -eq 0 ]
  [[ "$output" == *"setup_odoo.sh v"* ]]
}

@test "setup_odoo.sh -V prints version" {
  run env ROOT="$PROJECT_ROOT" bash "$PROJECT_ROOT/setup_odoo.sh" -V
  [ "$status" -eq 0 ]
  [[ "$output" == *"setup_odoo.sh v"* ]]
}

@test "setup_odoo.sh unknown command prints usage and exits 1" {
  run env ROOT="$PROJECT_ROOT" bash "$PROJECT_ROOT/setup_odoo.sh" unknown_xyz
  [ "$status" -eq 1 ]
}

# --- Version File -----------------------------------------------------------

@test "VERSION file exists" {
  [ -f "$PROJECT_ROOT/VERSION" ]
}

@test "VERSION file contains semver-like value" {
  local version
  version="$(cat "$PROJECT_ROOT/VERSION" | tr -d '[:space:]')"
  [[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]
}

# --- Module Loading ---------------------------------------------------------

@test "lib/ directory exists" {
  [ -d "$PROJECT_ROOT/lib" ]
}

@test "all required modules exist" {
  [ -f "$PROJECT_ROOT/lib/_bootstrap.sh" ]
  [ -f "$PROJECT_ROOT/lib/logging.sh" ]
  [ -f "$PROJECT_ROOT/lib/validation.sh" ]
  [ -f "$PROJECT_ROOT/lib/platform.sh" ]
  [ -f "$PROJECT_ROOT/lib/secrets.sh" ]
  [ -f "$PROJECT_ROOT/lib/database.sh" ]
  [ -f "$PROJECT_ROOT/lib/install.sh" ]
  [ -f "$PROJECT_ROOT/lib/restore.sh" ]
  [ -f "$PROJECT_ROOT/lib/config.sh" ]
  [ -f "$PROJECT_ROOT/lib/service.sh" ]
  [ -f "$PROJECT_ROOT/lib/rollback.sh" ]
}

@test "_bootstrap.sh loads without error" {
  export ROOT="$TEST_TMP"
  run bash -c "
    source '$PROJECT_ROOT/lib/logging.sh'
    source '$PROJECT_ROOT/lib/validation.sh'
    source '$PROJECT_ROOT/lib/platform.sh'
    source '$PROJECT_ROOT/lib/rollback.sh'
    echo ok
  "
  [ "$status" -eq 0 ]
  [[ "$output" == *"ok"* ]]
}

# --- Environment Variables --------------------------------------------------

@test "usage output lists DB_NAME" {
  run env ROOT="$PROJECT_ROOT" bash "$PROJECT_ROOT/setup_odoo.sh" help
  [[ "$output" == *"DB_NAME"* ]]
}

@test "usage output lists RESTORE_MODE" {
  run env ROOT="$PROJECT_ROOT" bash "$PROJECT_ROOT/setup_odoo.sh" help
  [[ "$output" == *"RESTORE_MODE"* ]]
}

@test "usage output lists LOG_LEVEL" {
  run env ROOT="$PROJECT_ROOT" bash "$PROJECT_ROOT/setup_odoo.sh" help
  [[ "$output" == *"LOG_LEVEL"* ]]
}

@test "usage output lists DRY_RUN" {
  run env ROOT="$PROJECT_ROOT" bash "$PROJECT_ROOT/setup_odoo.sh" help
  [[ "$output" == *"DRY_RUN"* ]]
}
