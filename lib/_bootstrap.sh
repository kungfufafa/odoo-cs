#!/usr/bin/env bash
# ============================================================================
# _bootstrap.sh — Module loader for setup_odoo library
# ============================================================================
# Sources all lib/*.sh modules in the correct dependency order.
# Must be sourced from setup_odoo.sh via: source "$LIB_DIR/_bootstrap.sh"
#
# This file also provides:
#   - SETUP_ODOO_VERSION from the VERSION file
#   - ensure_dirs() for creating required directories
#   - acquire_lock() / release_lock() for single-instance enforcement
#   - Dry-run mode support via DRY_RUN=1
# ============================================================================

[[ -n "${_BOOTSTRAP_SH_LOADED:-}" ]] && return 0
_BOOTSTRAP_SH_LOADED=1

# Resolve the lib directory path relative to this script.
LIB_DIR="${LIB_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}"

# Read version from VERSION file.
if [[ -f "$LIB_DIR/../VERSION" ]]; then
  SETUP_ODOO_VERSION="$(cat "$LIB_DIR/../VERSION" | tr -d '[:space:]')"
else
  SETUP_ODOO_VERSION="dev"
fi

# Dry-run mode: when enabled, destructive operations are logged but not executed.
DRY_RUN="${DRY_RUN:-0}"

# --- Source library modules in dependency order ---
# 1. Logging first (all other modules depend on log_* functions)
# 2. Validation (used by most modules for input checking)
# 3. Platform (system detection used by secrets, database, install)
# 4. Rollback (needed before any destructive operations)
# 5. Secrets, Database, Install, Restore, Config, Service

# shellcheck source=lib/logging.sh
source "$LIB_DIR/logging.sh"

# shellcheck source=lib/validation.sh
source "$LIB_DIR/validation.sh"

# shellcheck source=lib/platform.sh
source "$LIB_DIR/platform.sh"

# shellcheck source=lib/rollback.sh
source "$LIB_DIR/rollback.sh"

# shellcheck source=lib/secrets.sh
source "$LIB_DIR/secrets.sh"

# shellcheck source=lib/database.sh
source "$LIB_DIR/database.sh"

# shellcheck source=lib/install.sh
source "$LIB_DIR/install.sh"

# shellcheck source=lib/restore.sh
source "$LIB_DIR/restore.sh"

# shellcheck source=lib/config.sh
source "$LIB_DIR/config.sh"

# shellcheck source=lib/service.sh
source "$LIB_DIR/service.sh"

log_debug "loaded setup-odoo library v${SETUP_ODOO_VERSION} from $LIB_DIR"

# ============================================================================
# Shared utility functions used across modules
# ============================================================================

# Create all required working directories with secure permissions.
ensure_dirs() {
  mkdir -p "$ARTIFACTS_DIR" "$RESTORE_WORKDIR" "$ROOT/.logs" "$ROOT/.run" "$DATA_DIR"
  chmod 700 "$ARTIFACTS_DIR" "$RESTORE_WORKDIR" "$ROOT/.logs" "$ROOT/.run" "$DATA_DIR" 2>/dev/null || true
}

# Acquire an exclusive lock to prevent concurrent bootstrap runs.
# Uses a lock directory (mkdir is atomic on all filesystems).
# Dies if another bootstrap process is already running.
acquire_lock() {
  if mkdir "$LOCK_DIR" 2>/dev/null; then
    printf '%s\n' "$$" >"$LOCK_DIR/pid"
    trap 'release_lock' EXIT INT TERM
    return 0
  fi

  # Check if the existing lock holder is still alive
  if [[ -f "$LOCK_DIR/pid" ]]; then
    local existing_pid
    existing_pid="$(cat "$LOCK_DIR/pid" 2>/dev/null || true)"
    if [[ -n "$existing_pid" ]] && kill -0 "$existing_pid" 2>/dev/null; then
      log_fatal "another bootstrap is already running with pid $existing_pid"
    fi
  fi

  # Stale lock detected — clean up and re-acquire
  log_warn "removing stale lock directory"
  rm -rf "$LOCK_DIR"
  mkdir "$LOCK_DIR"
  printf '%s\n' "$$" >"$LOCK_DIR/pid"
  trap 'release_lock' EXIT INT TERM
}

# Release the bootstrap lock.
release_lock() {
  rm -rf "$LOCK_DIR"
}

# Clean up bootstrap PID file on exit.
cleanup_bootstrap_state() {
  rm -f "$BOOTSTRAP_PID_FILE"
}

# Set the exit trap for bootstrap operations (cleanup + lock release).
set_bootstrap_exit_trap() {
  trap 'cleanup_bootstrap_state; release_lock' EXIT INT TERM
}
