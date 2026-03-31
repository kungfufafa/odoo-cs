#!/usr/bin/env bats
# ============================================================================
# service.bats — Unit tests for lib/service.sh
# ============================================================================

load test_helper

setup() {
  setup_test_environment
  load_module "service.sh"
}

teardown() {
  teardown_test_environment
}

@test "healthcheck_url uses explicit interface host" {
  export ODOO_HTTP_INTERFACE="10.20.30.40"

  result="$(healthcheck_url)"

  [ "$result" = "http://10.20.30.40:8069/web/login" ]
}

@test "healthcheck_url maps wildcard IPv4 interface to loopback" {
  export ODOO_HTTP_INTERFACE="0.0.0.0"

  result="$(healthcheck_url)"

  [ "$result" = "http://127.0.0.1:8069/web/login" ]
}

@test "healthcheck_url wraps IPv6 interface in brackets" {
  export ODOO_HTTP_INTERFACE="::1"

  result="$(healthcheck_url)"

  [ "$result" = "http://[::1]:8069/web/login" ]
}

@test "ensure_background_privilege_escalation requires noninteractive sudo on ubuntu" {
  local calls_file="$TEST_TMP/background_privilege_calls.txt"

  detect_platform() {
    OS_FAMILY="linux"
    LINUX_DISTRO="ubuntu"
  }
  require_noninteractive_sudo_for_background() {
    printf 'checked\n' >>"$calls_file"
  }

  run ensure_background_privilege_escalation

  [ "$status" -eq 0 ]
  [ "$(cat "$calls_file")" = "checked" ]
}

@test "prepare_odoo_runtime runs dependency preflight after loading runtime env" {
  local calls_file="$TEST_TMP/runtime_calls.txt"

  load_runtime_env() {
    export ODOO_BIN="/usr/bin/odoo"
    printf 'load\n' >>"$calls_file"
  }
  detect_platform() {
    OS_FAMILY="linux"
    printf 'platform\n' >>"$calls_file"
  }
  ensure_odoo_runtime_python_dependencies() {
    printf 'preflight\n' >>"$calls_file"
  }

  run prepare_odoo_runtime

  [ "$status" -eq 0 ]
  [ "$(cat "$calls_file")" = $'load\nplatform\npreflight' ]
}

@test "load_runtime_env preserves explicit dependency repair overrides" {
  cat > "$RUNTIME_ENV_FILE" <<'EOF'
ODOO_BIN=/usr/bin/odoo
ODOO_RUNTIME_AUTO_REPAIR=1
ODOO_DEPENDENCY_REPAIR_RETRIES=3
ODOO_DEPENDENCY_REPAIR_RETRY_DELAY=5
EOF

  export ODOO_RUNTIME_AUTO_REPAIR="0"
  export ODOO_DEPENDENCY_REPAIR_RETRIES="9"
  export ODOO_DEPENDENCY_REPAIR_RETRY_DELAY="11"

  load_runtime_env

  [ "$ODOO_BIN" = "/usr/bin/odoo" ]
  [ "$ODOO_RUNTIME_AUTO_REPAIR" = "0" ]
  [ "$ODOO_DEPENDENCY_REPAIR_RETRIES" = "9" ]
  [ "$ODOO_DEPENDENCY_REPAIR_RETRY_DELAY" = "11" ]
}
