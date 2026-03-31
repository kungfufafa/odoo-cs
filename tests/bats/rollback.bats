#!/usr/bin/env bats
# ============================================================================
# rollback.bats — Unit tests for lib/rollback.sh
# ============================================================================

load test_helper

setup() {
  setup_test_environment
  export ROLLBACK_DIR="$TEST_TMP/.rollback"
  load_module "rollback.sh"
}

teardown() {
  teardown_test_environment
}

# --- rollback_init ----------------------------------------------------------

@test "rollback_init creates rollback directory" {
  rollback_init
  [ -d "$ROLLBACK_DIR" ]
}

@test "rollback_init creates timestamp file" {
  rollback_init
  [ -f "$ROLLBACK_DIR/.init_timestamp" ]
}

@test "rollback_init arms ERR trap" {
  rollback_init
  [[ "$(trap -p ERR)" == *"_rollback_on_error"* ]]
}

@test "rollback_init resets stack" {
  _ROLLBACK_STACK=("leftover||true")
  rollback_init
  [ "${#_ROLLBACK_STACK[@]}" -eq 0 ]
}

# --- rollback_register ------------------------------------------------------

@test "rollback_register adds to stack" {
  rollback_init
  rollback_register "test action" "echo undo"
  [ "${#_ROLLBACK_STACK[@]}" -eq 1 ]
}

@test "rollback_register persists to disk" {
  rollback_init
  rollback_register "test action" "echo undo"
  [ -f "$ROLLBACK_DIR/action_1.sh" ]
  [ -f "$ROLLBACK_DIR/action_1.desc" ]
}

@test "rollback_register supports multiple actions" {
  rollback_init
  rollback_register "action 1" "echo 1"
  rollback_register "action 2" "echo 2"
  rollback_register "action 3" "echo 3"
  [ "${#_ROLLBACK_STACK[@]}" -eq 3 ]
}

@test "rollback_register is no-op when not initialized" {
  _ROLLBACK_INITIALIZED=0
  _ROLLBACK_STACK=()
  rollback_register "should not add" "echo nope"
  [ "${#_ROLLBACK_STACK[@]}" -eq 0 ]
}

# --- rollback_execute -------------------------------------------------------

@test "rollback_execute runs actions in reverse order" {
  rollback_init
  local marker_file="$TEST_TMP/rollback_order.txt"
  rollback_register "first" "printf '1\n' >> '$marker_file'"
  rollback_register "second" "printf '2\n' >> '$marker_file'"
  rollback_register "third" "printf '3\n' >> '$marker_file'"
  rollback_execute

  # Should be 3, 2, 1 (reverse order)
  local first second third
  first="$(sed -n '1p' "$marker_file")"
  second="$(sed -n '2p' "$marker_file")"
  third="$(sed -n '3p' "$marker_file")"
  [ "$first" = "3" ]
  [ "$second" = "2" ]
  [ "$third" = "1" ]
}

@test "rollback_execute clears stack after execution" {
  rollback_init
  rollback_register "test" "true"
  rollback_execute
  [ "${#_ROLLBACK_STACK[@]}" -eq 0 ]
}

@test "rollback_execute handles empty stack" {
  rollback_init
  run rollback_execute
  [ "$status" -eq 0 ]
}

@test "rollback_execute continues after individual action failure" {
  rollback_init
  local marker_file="$TEST_TMP/continued.txt"
  rollback_register "will succeed" "printf 'ok\n' >> '$marker_file'"
  rollback_register "will fail" "false"
  rollback_register "also succeeds" "printf 'also\n' >> '$marker_file'"
  rollback_execute

  # Both successful actions should have run despite the middle one failing
  [ -f "$marker_file" ]
  local count
  count="$(wc -l < "$marker_file" | tr -d ' ')"
  [ "$count" -eq 2 ]
}

# --- rollback_clear ---------------------------------------------------------

@test "rollback_clear removes rollback directory" {
  rollback_init
  rollback_register "test" "true"
  rollback_clear
  [ ! -d "$ROLLBACK_DIR" ]
}

@test "rollback_clear resets stack" {
  rollback_init
  rollback_register "test" "true"
  rollback_clear
  [ "${#_ROLLBACK_STACK[@]}" -eq 0 ]
}

@test "rollback_clear removes ERR trap" {
  rollback_init
  rollback_clear
  [ -z "$(trap -p ERR)" ]
}
