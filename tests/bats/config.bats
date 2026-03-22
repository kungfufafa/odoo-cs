#!/usr/bin/env bats
# ============================================================================
# config.bats — Unit tests for lib/config.sh
# ============================================================================

load test_helper

setup() {
  setup_test_environment
  export OS_FAMILY="linux"
  export LINUX_DISTRO="ubuntu"
  export ODOO_SRC_DIR="$TEST_TMP/odoo-src"
  export CUSTOM_ADDONS_DIR="$TEST_TMP/addons"
  mkdir -p "$ODOO_SRC_DIR/odoo/addons" "$CUSTOM_ADDONS_DIR" "$DATA_DIR"
  load_module "platform.sh"
  load_module "config.sh"
}

teardown() {
  teardown_test_environment
}

# --- odoo_bool --------------------------------------------------------------

@test "odoo_bool returns True for 1" {
  result="$(odoo_bool "1")"
  [ "$result" = "True" ]
}

@test "odoo_bool returns False for 0" {
  result="$(odoo_bool "0")"
  [ "$result" = "False" ]
}

# --- resolved_odoo_workers --------------------------------------------------

@test "resolved_odoo_workers returns explicit value when not auto" {
  export ODOO_WORKERS="4"
  result="$(resolved_odoo_workers)"
  [ "$result" = "4" ]
}

@test "resolved_odoo_workers returns 0 for low memory" {
  export ODOO_WORKERS="auto"
  # Override the cache to simulate low memory
  _MEMORY_GB_CACHE="2"
  result="$(resolved_odoo_workers)"
  [ "$result" = "0" ]
}

# --- resolved_memory_soft ---------------------------------------------------

@test "resolved_memory_soft returns explicit value when not auto" {
  export ODOO_LIMIT_MEMORY_SOFT="4294967296"
  result="$(resolved_memory_soft)"
  [ "$result" = "4294967296" ]
}

@test "resolved_memory_soft returns default 2GB for unknown memory" {
  export ODOO_LIMIT_MEMORY_SOFT="auto"
  _MEMORY_GB_CACHE="0"
  result="$(resolved_memory_soft)"
  [ "$result" = "2147483648" ]
}

# --- resolved_memory_hard ---------------------------------------------------

@test "resolved_memory_hard returns explicit value when not auto" {
  export ODOO_LIMIT_MEMORY_HARD="5368709120"
  result="$(resolved_memory_hard)"
  [ "$result" = "5368709120" ]
}

@test "resolved_memory_hard is 1.2x soft limit" {
  export ODOO_LIMIT_MEMORY_SOFT="2147483648"
  export ODOO_LIMIT_MEMORY_HARD="auto"
  result="$(resolved_memory_hard)"
  expected=$(( 2147483648 * 12 / 10 ))
  [ "$result" = "$expected" ]
}

# --- write_odoo_conf --------------------------------------------------------

@test "write_odoo_conf creates odoo.conf" {
  write_odoo_conf
  [ -f "$ROOT/odoo.conf" ]
}

@test "write_odoo_conf includes all required sections" {
  write_odoo_conf
  grep -q "\[options\]" "$ROOT/odoo.conf"
  grep -q "db_host" "$ROOT/odoo.conf"
  grep -q "db_port" "$ROOT/odoo.conf"
  grep -q "db_user" "$ROOT/odoo.conf"
  grep -q "addons_path" "$ROOT/odoo.conf"
  grep -q "workers" "$ROOT/odoo.conf"
}

@test "write_odoo_conf sets chmod 600" {
  write_odoo_conf
  local perms
  perms="$(stat -c '%a' "$ROOT/odoo.conf" 2>/dev/null || stat -f '%Lp' "$ROOT/odoo.conf")"
  [[ "$perms" =~ ^0?600$ ]]
}

@test "write_odoo_conf includes ODOO_SRC_DIR in addons_path" {
  write_odoo_conf
  grep -q "$ODOO_SRC_DIR/odoo/addons" "$ROOT/odoo.conf"
}

# --- write_runtime_env ------------------------------------------------------

@test "write_runtime_env creates runtime file" {
  write_runtime_env
  [ -f "$RUNTIME_ENV_FILE" ]
}

@test "write_runtime_env contains required keys" {
  write_runtime_env
  grep -q "ROOT=" "$RUNTIME_ENV_FILE"
  grep -q "DB_NAME=" "$RUNTIME_ENV_FILE"
  grep -q "ODOO_HTTP_PORT=" "$RUNTIME_ENV_FILE"
}
