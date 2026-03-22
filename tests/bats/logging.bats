#!/usr/bin/env bats
# ============================================================================
# logging.bats — Unit tests for lib/logging.sh
# ============================================================================

load test_helper

setup() {
  setup_test_environment
  export LOG_LEVEL="DEBUG"  # Enable all levels for testing
  export LOG_OUTPUT="$TEST_TMP/test.log"
  load_module "logging.sh"
}

teardown() {
  teardown_test_environment
}

# --- Log Level Filtering ---------------------------------------------------

@test "log_debug emits when LOG_LEVEL=DEBUG" {
  export LOG_LEVEL="DEBUG"
  _LOGGING_SH_LOADED=""
  load_module "logging.sh"
  log_debug "test debug message"
  grep -q "DEBUG" "$TEST_TMP/test.log"
}

@test "log_debug does NOT emit when LOG_LEVEL=INFO" {
  export LOG_LEVEL="INFO"
  _LOGGING_SH_LOADED=""
  load_module "logging.sh"
  : > "$TEST_TMP/test.log"
  log_debug "should not appear"
  [ ! -s "$TEST_TMP/test.log" ]
}

@test "log_info emits at INFO level" {
  log_info "test info message"
  grep -q "INFO" "$TEST_TMP/test.log"
  grep -q "test info message" "$TEST_TMP/test.log"
}

@test "log_warn emits at WARN level" {
  log_warn "test warning"
  grep -q "WARN" "$TEST_TMP/test.log"
}

@test "log_error emits at ERROR level" {
  log_error "test error"
  grep -q "ERROR" "$TEST_TMP/test.log"
}

# --- Timestamp Format -------------------------------------------------------

@test "log output includes ISO8601 timestamp" {
  log_info "timestamp test"
  # Match pattern like [2026-03-22T12:00:00+0700]
  grep -Eq '\[20[0-9]{2}-[0-9]{2}-[0-9]{2}T' "$TEST_TMP/test.log"
}

# --- JSON Format ------------------------------------------------------------

@test "LOG_FORMAT=json produces JSON output" {
  export LOG_FORMAT="json"
  _LOGGING_SH_LOADED=""
  load_module "logging.sh"
  log_info "json test"
  grep -q '"level":"INFO"' "$TEST_TMP/test.log"
  grep -q '"message":"json test"' "$TEST_TMP/test.log"
}

# --- Component Tag ----------------------------------------------------------

@test "log output includes setup-odoo component tag" {
  log_info "component test"
  grep -q "setup-odoo" "$TEST_TMP/test.log"
}

# --- Backward Compatibility -------------------------------------------------

@test "log() function works as alias for log_info" {
  log "backward compat test"
  grep -q "INFO" "$TEST_TMP/test.log"
  grep -q "backward compat test" "$TEST_TMP/test.log"
}

# --- Level Numeric Mapping --------------------------------------------------

@test "_log_level_to_num returns correct values" {
  [ "$(_log_level_to_num "DEBUG")" = "0" ]
  [ "$(_log_level_to_num "INFO")" = "1" ]
  [ "$(_log_level_to_num "WARN")" = "2" ]
  [ "$(_log_level_to_num "ERROR")" = "3" ]
  [ "$(_log_level_to_num "FATAL")" = "4" ]
}

@test "_log_level_to_num defaults unknown levels to INFO(1)" {
  [ "$(_log_level_to_num "UNKNOWN")" = "1" ]
}
