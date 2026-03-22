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
