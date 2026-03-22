#!/usr/bin/env bash
# ============================================================================
# rollback.sh — State snapshot and rollback mechanism
# ============================================================================
# Provides a stack-based rollback system that records undo actions during
# bootstrap operations. If the bootstrap fails (ERR trap), all registered
# undo actions are executed in reverse order to restore the previous state.
#
# Usage:
#   rollback_init          — Initialize the rollback stack
#   rollback_register      — Register an undo action with description
#   rollback_execute       — Execute all undo actions in reverse
#   rollback_clear         — Clear the rollback stack (on success)
# ============================================================================

[[ -n "${_ROLLBACK_SH_LOADED:-}" ]] && return 0
_ROLLBACK_SH_LOADED=1

# Directory where rollback state is persisted.
ROLLBACK_DIR="${ROLLBACK_DIR:-$ROOT/.rollback}"

# In-memory rollback stack (array of "description||command" entries).
_ROLLBACK_STACK=()

# Whether rollback has been initialized.
_ROLLBACK_INITIALIZED=0

# Guard flag to prevent recursive rollback execution.
_ROLLBACK_ACTIVE=0

# Initialize the rollback system.
# Creates the rollback directory and sets up the ERR trap for automatic rollback.
rollback_init() {
  mkdir -p "$ROLLBACK_DIR"
  _ROLLBACK_STACK=()
  _ROLLBACK_INITIALIZED=1
  _ROLLBACK_ACTIVE=0

  # Persist initialization timestamp
  printf '%s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" >"$ROLLBACK_DIR/.init_timestamp"
  trap '_rollback_on_error' ERR

  log_debug "rollback system initialized"
}

# Register an undo action on the rollback stack.
# Actions are executed in LIFO order if rollback_execute is called.
# Arguments: $1=description, $2=shell command to undo the action
rollback_register() {
  local description="$1"
  local undo_command="$2"

  if (( _ROLLBACK_INITIALIZED == 0 )); then
    log_debug "rollback not initialized, skipping registration: $description"
    return 0
  fi

  _ROLLBACK_STACK+=("${description}||${undo_command}")

  # Also persist to disk for crash recovery
  local index=${#_ROLLBACK_STACK[@]}
  printf '%s\n' "$undo_command" >"$ROLLBACK_DIR/action_${index}.sh"
  printf '%s\n' "$description" >"$ROLLBACK_DIR/action_${index}.desc"

  log_debug "rollback registered: $description"
}

# Execute all registered undo actions in reverse order (LIFO).
# Called automatically on ERR trap, or manually if needed.
# Each action failure is logged but does not prevent subsequent actions.
rollback_execute() {
  local count=${#_ROLLBACK_STACK[@]}

  if (( _ROLLBACK_ACTIVE == 1 )); then
    log_debug "rollback already in progress"
    return 0
  fi

  _ROLLBACK_ACTIVE=1
  trap - ERR

  if (( count == 0 )); then
    log_debug "no rollback actions registered"
    _ROLLBACK_ACTIVE=0
    return 0
  fi

  log_warn "executing rollback: $count action(s) to undo"

  local i entry description undo_command
  for (( i = count - 1; i >= 0; i-- )); do
    entry="${_ROLLBACK_STACK[$i]}"
    description="${entry%%||*}"
    undo_command="${entry#*||}"

    log_warn "  rollback [$((count - i))/$count]: $description"
    if eval "$undo_command" 2>/dev/null; then
      log_info "  rollback action succeeded: $description"
    else
      log_error "  rollback action failed: $description (command: $undo_command)"
    fi
  done

  _ROLLBACK_STACK=()
  _ROLLBACK_ACTIVE=0
  log_warn "rollback complete"
}

# Clear the rollback stack (called on successful completion).
# Removes persisted rollback state from disk.
rollback_clear() {
  _ROLLBACK_STACK=()
  if [[ -d "$ROLLBACK_DIR" ]]; then
    rm -rf "$ROLLBACK_DIR"
    log_debug "rollback state cleared"
  fi
  _ROLLBACK_INITIALIZED=0
  _ROLLBACK_ACTIVE=0
  trap - ERR
}

# Trigger rollback when the bootstrap exits via an explicit fatal path.
# Arguments: $1=exit code to associate with the failure
rollback_on_fatal() {
  local exit_code="${1:-1}"
  if (( _ROLLBACK_INITIALIZED == 0 || _ROLLBACK_ACTIVE == 1 )); then
    return 0
  fi

  log_error "bootstrap failed with exit code $exit_code — initiating automatic rollback"
  rollback_execute
}

# Trap handler for ERR that triggers automatic rollback.
# This is registered by rollback_init and fires on any unhandled error.
_rollback_on_error() {
  local exit_code=$?
  rollback_on_fatal "$exit_code"
  return "$exit_code"
}
