#!/usr/bin/env bats
# ============================================================================
# validation.bats — Unit tests for lib/validation.sh
# ============================================================================

load test_helper

setup() {
  setup_test_environment
  load_module "validation.sh"
}

teardown() {
  teardown_test_environment
}

# --- Port Validation --------------------------------------------------------

@test "validate_port accepts valid port 8069" {
  run validate_port "TEST_PORT" "8069"
  [ "$status" -eq 0 ]
}

@test "validate_port accepts port 1" {
  run validate_port "TEST_PORT" "1"
  [ "$status" -eq 0 ]
}

@test "validate_port accepts port 65535" {
  run validate_port "TEST_PORT" "65535"
  [ "$status" -eq 0 ]
}

@test "validate_port rejects port 0" {
  run validate_port "TEST_PORT" "0"
  [ "$status" -eq 1 ]
}

@test "validate_port rejects port 65536" {
  run validate_port "TEST_PORT" "65536"
  [ "$status" -eq 1 ]
}

@test "validate_port rejects non-numeric value" {
  run validate_port "TEST_PORT" "abc"
  [ "$status" -eq 1 ]
}

@test "validate_port rejects negative value" {
  run validate_port "TEST_PORT" "-1"
  [ "$status" -eq 1 ]
}

@test "validate_port rejects empty value" {
  run validate_port "TEST_PORT" ""
  [ "$status" -eq 1 ]
}

# --- Non-Negative Integer Validation ----------------------------------------

@test "validate_non_negative_int accepts 0" {
  run validate_non_negative_int "TEST_INT" "0"
  [ "$status" -eq 0 ]
}

@test "validate_non_negative_int accepts 42" {
  run validate_non_negative_int "TEST_INT" "42"
  [ "$status" -eq 0 ]
}

@test "validate_non_negative_int rejects negative" {
  run validate_non_negative_int "TEST_INT" "-5"
  [ "$status" -eq 1 ]
}

@test "validate_non_negative_int rejects text" {
  run validate_non_negative_int "TEST_INT" "abc"
  [ "$status" -eq 1 ]
}

# --- Positive Integer Validation --------------------------------------------

@test "validate_positive_int accepts 1" {
  run validate_positive_int "TEST_INT" "1"
  [ "$status" -eq 0 ]
}

@test "validate_positive_int rejects 0" {
  run validate_positive_int "TEST_INT" "0"
  [ "$status" -eq 1 ]
}

# --- Boolean Validation -----------------------------------------------------

@test "validate_boolean accepts 0" {
  run validate_boolean "TEST_BOOL" "0"
  [ "$status" -eq 0 ]
}

@test "validate_boolean accepts 1" {
  run validate_boolean "TEST_BOOL" "1"
  [ "$status" -eq 0 ]
}

@test "validate_boolean rejects 2" {
  run validate_boolean "TEST_BOOL" "2"
  [ "$status" -eq 1 ]
}

@test "validate_boolean rejects true" {
  run validate_boolean "TEST_BOOL" "true"
  [ "$status" -eq 1 ]
}

# --- Enum Validation --------------------------------------------------------

@test "validate_enum accepts valid value" {
  run validate_enum "TEST_ENUM" "refresh" refresh reuse fail
  [ "$status" -eq 0 ]
}

@test "validate_enum accepts another valid value" {
  run validate_enum "TEST_ENUM" "reuse" refresh reuse fail
  [ "$status" -eq 0 ]
}

@test "validate_enum rejects invalid value" {
  run validate_enum "TEST_ENUM" "invalid" refresh reuse fail
  [ "$status" -eq 1 ]
}

# --- Database Name Validation -----------------------------------------------

@test "validate_db_name accepts valid name" {
  run validate_db_name "DB_NAME" "mkli_local"
  [ "$status" -eq 0 ]
}

@test "validate_db_name accepts underscore-prefixed name" {
  run validate_db_name "DB_NAME" "_test_db"
  [ "$status" -eq 0 ]
}

@test "validate_db_name rejects empty name" {
  run validate_db_name "DB_NAME" ""
  [ "$status" -eq 1 ]
}

@test "validate_db_name rejects name starting with digit" {
  run validate_db_name "DB_NAME" "123db"
  [ "$status" -eq 1 ]
}

@test "validate_db_name rejects name with special chars" {
  run validate_db_name "DB_NAME" "my-db"
  [ "$status" -eq 1 ]
}

@test "validate_db_name rejects name with spaces" {
  run validate_db_name "DB_NAME" "my db"
  [ "$status" -eq 1 ]
}

@test "validate_db_name rejects name longer than 63 chars" {
  local long_name
  long_name="$(printf 'a%.0s' $(seq 1 64))"
  run validate_db_name "DB_NAME" "$long_name"
  [ "$status" -eq 1 ]
}

@test "validate_db_name accepts 63-char name" {
  local name63
  name63="$(printf 'a%.0s' $(seq 1 63))"
  run validate_db_name "DB_NAME" "$name63"
  [ "$status" -eq 0 ]
}

# --- Auto-or-Positive-Int Validation ----------------------------------------

@test "validate_auto_or_positive_int accepts 'auto'" {
  run validate_auto_or_positive_int "WORKERS" "auto"
  [ "$status" -eq 0 ]
}

@test "validate_auto_or_positive_int accepts integer" {
  run validate_auto_or_positive_int "WORKERS" "4"
  [ "$status" -eq 0 ]
}

@test "validate_auto_or_positive_int rejects text" {
  run validate_auto_or_positive_int "WORKERS" "many"
  [ "$status" -eq 1 ]
}

# --- Path Sanitization ------------------------------------------------------

@test "sanitize_path removes trailing slash" {
  result="$(sanitize_path "/foo/bar/")"
  [ "$result" = "/foo/bar" ]
}

@test "sanitize_path keeps root slash" {
  result="$(sanitize_path "/")"
  [ "$result" = "/" ]
}

@test "sanitize_path handles no trailing slash" {
  result="$(sanitize_path "/foo/bar")"
  [ "$result" = "/foo/bar" ]
}

# --- Full Validation --------------------------------------------------------

@test "validate_all_inputs passes with valid defaults" {
  run validate_all_inputs
  [ "$status" -eq 0 ]
}

@test "validate_all_inputs fails with invalid port" {
  export ODOO_HTTP_PORT="99999"
  run validate_all_inputs
  [ "$status" -eq 1 ]
}

@test "validate_all_inputs fails with invalid ODOO_EXPOSE_HTTP" {
  export ODOO_EXPOSE_HTTP="2"
  run validate_all_inputs
  [ "$status" -eq 1 ]
}

@test "validate_all_inputs fails with invalid boolean" {
  export ODOO_PROXY_MODE="yes"
  run validate_all_inputs
  [ "$status" -eq 1 ]
}

@test "validate_all_inputs fails with invalid enum" {
  export RESTORE_MODE="invalid"
  run validate_all_inputs
  [ "$status" -eq 1 ]
}

@test "validate_all_inputs rejects DRY_RUN preview mode" {
  export DRY_RUN="1"
  run validate_all_inputs
  [ "$status" -eq 1 ]
}
