#!/usr/bin/env bats
# ============================================================================
# platform.bats — Unit tests for lib/platform.sh
# ============================================================================

load test_helper

setup() {
  setup_test_environment
  load_module "platform.sh"
}

teardown() {
  teardown_test_environment
}

# --- require_cmd ------------------------------------------------------------

@test "require_cmd succeeds for existing command" {
  run require_cmd "bash"
  [ "$status" -eq 0 ]
}

@test "require_cmd fails for nonexistent command" {
  run require_cmd "nonexistent_command_xyz_12345"
  [ "$status" -ne 0 ]
}

@test "run_privileged bypasses sudo when already root" {
  export PATH="$MOCK_BIN:$PATH"
  create_mock "id" "0"
  create_mock "echo_root" "ok"
  create_mock "sudo" "" 99

  run run_privileged echo_root

  [ "$status" -eq 0 ]
  [[ "$output" == *"ok"* ]]
}

@test "require_noninteractive_sudo_for_background accepts root without sudo" {
  export PATH="$MOCK_BIN:$PATH"
  create_mock "id" "0"
  create_mock "sudo" "" 99

  run require_noninteractive_sudo_for_background

  [ "$status" -eq 0 ]
}

@test "run_privileged fails fast without tty when sudo cannot run non-interactively" {
  export PATH="$MOCK_BIN:$PATH"
  create_mock "id" "1000"
  create_mock "sudo" "" 1

  shell_has_tty() {
    return 1
  }

  run run_privileged true

  [ "$status" -ne 0 ]
  [[ "$output" == *"command requires sudo but no terminal is available"* ]]
}

@test "run_privileged returns the wrapped command status" {
  export PATH="$MOCK_BIN:$PATH"
  create_mock "id" "1000"
  create_mock "sudo" "" 42

  shell_has_tty() {
    return 0
  }

  run run_privileged true

  [ "$status" -eq 42 ]
}

# --- detect_platform --------------------------------------------------------

@test "detect_platform sets OS_FAMILY" {
  detect_platform
  [ -n "$OS_FAMILY" ]
  [[ "$OS_FAMILY" == "linux" || "$OS_FAMILY" == "macos" || "$OS_FAMILY" == "windows" ]]
}

@test "detect_platform is idempotent" {
  detect_platform
  local first_os="$OS_FAMILY"
  detect_platform
  [ "$OS_FAMILY" = "$first_os" ]
}

# --- detect_cpu_count -------------------------------------------------------

@test "detect_cpu_count returns a positive integer" {
  local count
  count="$(detect_cpu_count)"
  [[ "$count" =~ ^[0-9]+$ ]]
  (( count >= 1 ))
}

@test "detect_cpu_count caches result" {
  local first second
  first="$(detect_cpu_count)"
  second="$(detect_cpu_count)"
  [ "$first" = "$second" ]
}

# --- detect_memory_gb -------------------------------------------------------

@test "detect_memory_gb returns a non-negative integer" {
  detect_platform
  local mem
  mem="$(detect_memory_gb)"
  [[ "$mem" =~ ^[0-9]+$ ]]
}

# --- pick_file --------------------------------------------------------------

@test "pick_file returns empty for no matches" {
  local result
  result="$(pick_file 'nonexistent_pattern_*.xyz')"
  [ -z "$result" ]
}

@test "pick_file finds matching file" {
  touch "$ROOT/odoo_test.tar.gz"
  local result
  result="$(pick_file 'odoo*.tar.gz')"
  [ -n "$result" ]
  [[ "$result" == *"odoo_test.tar.gz" ]]
}
