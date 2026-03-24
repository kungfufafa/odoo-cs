#!/usr/bin/env bash
# ============================================================================
# service.sh — Odoo process lifecycle management
# ============================================================================
# Handles: starting/stopping Odoo and bootstrap processes, PID file
# management, healthchecks, and signal handlers for graceful shutdown.
# ============================================================================

[[ -n "${_SERVICE_SH_LOADED:-}" ]] && return 0
_SERVICE_SH_LOADED=1

# Timeout (seconds) before SIGKILL after sending SIGTERM.
STOP_TIMEOUT="${STOP_TIMEOUT:-30}"

# Detached bootstrap on Ubuntu/Debian cannot answer sudo password prompts.
# Fail early unless the shell is already root or sudo is non-interactive.
ensure_background_privilege_escalation() {
  detect_platform
  [[ "$OS_FAMILY" == "linux" ]] || return 0
  [[ "$LINUX_DISTRO" == "ubuntu" || "$LINUX_DISTRO" == "debian" ]] || return 0
  require_noninteractive_sudo_for_background
}

# Read the PID value from a PID file.
# Arguments: $1=PID file path
# Output: PID value on stdout (empty if file doesn't exist)
read_pid_file() {
  local file="$1"
  if [[ -f "$file" ]]; then
    cat "$file"
  fi
}

# Check whether a given PID is still running.
# Arguments: $1=PID value
# Returns: 0 if running, 1 otherwise
pid_is_running() {
  local pid="$1"
  [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null
}

# Load the runtime environment file (written by bootstrap).
load_runtime_env() {
  local runtime_auto_repair_override="${ODOO_RUNTIME_AUTO_REPAIR-__unset__}"
  local runtime_retries_override="${ODOO_DEPENDENCY_REPAIR_RETRIES-__unset__}"
  local runtime_retry_delay_override="${ODOO_DEPENDENCY_REPAIR_RETRY_DELAY-__unset__}"

  if [[ -f "$RUNTIME_ENV_FILE" ]]; then
    # shellcheck disable=SC1090
    source "$RUNTIME_ENV_FILE"
  fi

  if [[ "$runtime_auto_repair_override" != "__unset__" ]]; then
    ODOO_RUNTIME_AUTO_REPAIR="$runtime_auto_repair_override"
  fi
  if [[ "$runtime_retries_override" != "__unset__" ]]; then
    ODOO_DEPENDENCY_REPAIR_RETRIES="$runtime_retries_override"
  fi
  if [[ "$runtime_retry_delay_override" != "__unset__" ]]; then
    ODOO_DEPENDENCY_REPAIR_RETRY_DELAY="$runtime_retry_delay_override"
  fi
}

# Prepare environment variables and dependency preflight before launching Odoo.
prepare_odoo_runtime() {
  load_runtime_env
  detect_platform

  # macOS: Add Homebrew PostgreSQL and library paths
  if [[ "$OS_FAMILY" == "macos" ]]; then
    export PATH="/opt/homebrew/opt/postgresql@16/bin:/opt/homebrew/opt/libpq/bin:$PATH"
    export DYLD_LIBRARY_PATH="/opt/homebrew/opt/libpq/lib:/opt/homebrew/opt/openldap/lib:${DYLD_LIBRARY_PATH:-}"
  fi

  ensure_odoo_runtime_python_dependencies
}

# Run Odoo in the foreground (exec replaces the current process).
# Sets up platform-specific library paths before launching.
# Arguments: passed through to Odoo binary
run_odoo() {
  local odoo_conf
  prepare_odoo_runtime
  odoo_conf="${ODOO_CONF:-$ROOT/odoo.conf}"

  if [[ -n "${ODOO_BIN:-}" ]]; then
    exec "$ODOO_BIN" -c "$odoo_conf" "$@"
  fi

  [[ -n "${ODOO_SRC_DIR:-}" ]] || log_fatal "ODOO_SRC_DIR not set"
  exec "$VENV_DIR/bin/python" "$ODOO_SRC_DIR/setup/odoo" -c "$odoo_conf" "$@"
}

# Start Odoo as a detached background process.
# Writes PID to ODOO_PID_FILE, redirects output to ODOO_STDOUT_LOG.
# Arguments: passed through to Odoo via 'run' command
start_odoo_detached() {
  local pid
  ensure_dirs
  pid="$(read_pid_file "$ODOO_PID_FILE")"
  if pid_is_running "$pid"; then
    log_info "odoo already running with pid $pid"
    return 0
  fi

  : >"$ODOO_STDOUT_LOG"
  nohup env ROOT="$ROOT" "$ROOT/setup_odoo.sh" run "$@" >>"$ODOO_STDOUT_LOG" 2>&1 &
  echo "$!" >"$ODOO_PID_FILE"
  log_info "started Odoo pid=$!"
  log_info "stdout log=$ODOO_STDOUT_LOG"
}

# Resolve the HTTP host to use for local healthchecks.
# Wildcard binds are translated back to a reachable loopback address.
resolved_healthcheck_host() {
  local host="${ODOO_HTTP_INTERFACE:-127.0.0.1}"
  host="${host#[}"
  host="${host%]}"

  case "$host" in
    ""|0.0.0.0)
      printf '127.0.0.1\n'
      ;;
    ::)
      printf '::1\n'
      ;;
    *)
      printf '%s\n' "$host"
      ;;
  esac
}

# Build the login URL used by the Odoo healthcheck.
healthcheck_url() {
  local host
  host="$(resolved_healthcheck_host)"

  if [[ "$host" == *:* ]]; then
    printf 'http://[%s]:%s/web/login\n' "$host" "$ODOO_HTTP_PORT"
  else
    printf 'http://%s:%s/web/login\n' "$host" "$ODOO_HTTP_PORT"
  fi
}

# Wait for Odoo to become healthy by polling the login page.
# Also checks DB connectivity if psql is available.
# Dies if healthcheck fails after HEALTHCHECK_TIMEOUT seconds.
healthcheck_odoo() {
  local deadline url
  url="$(healthcheck_url)"
  deadline=$((SECONDS + HEALTHCHECK_TIMEOUT))

  log_info "waiting for Odoo healthcheck at $url (timeout: ${HEALTHCHECK_TIMEOUT}s)"
  while (( SECONDS < deadline )); do
    if command -v curl >/dev/null 2>&1 && curl -fsS -o /dev/null "$url" 2>/dev/null; then
      log_info "healthcheck passed: $url"
      return 0
    fi
    sleep 2
  done
  log_fatal "healthcheck failed after ${HEALTHCHECK_TIMEOUT}s: $url"
}

# Stop a process by its PID file with graceful shutdown.
# Sends SIGTERM first, waits STOP_TIMEOUT seconds, then SIGKILL if needed.
# Arguments: $1=PID file path, $2=label for log messages
stop_pid_file() {
  local file="$1"
  local label="$2"
  local pid wait_count

  pid="$(read_pid_file "$file")"
  if pid_is_running "$pid"; then
    log_info "sending SIGTERM to $label (pid $pid)"
    kill "$pid" 2>/dev/null || true

    # Wait for graceful shutdown
    wait_count=0
    while pid_is_running "$pid" && (( wait_count < STOP_TIMEOUT )); do
      sleep 1
      (( wait_count++ ))
    done

    if pid_is_running "$pid"; then
      log_warn "$label did not stop within ${STOP_TIMEOUT}s, sending SIGKILL"
      kill -9 "$pid" 2>/dev/null || true
    fi

    log_info "stopped $label pid $pid"
  else
    log_debug "$label not running (pid file: $file)"
  fi
  rm -f "$file"
}

# Start the bootstrap process in the background.
# Writes bootstrap PID to BOOTSTRAP_PID_FILE.
start_background() {
  local pid
  ensure_dirs
  ensure_background_privilege_escalation
  pid="$(read_pid_file "$BOOTSTRAP_PID_FILE")"
  if pid_is_running "$pid"; then
    log_info "bootstrap already running with pid $pid"
    return 0
  fi

  log_info "starting detached bootstrap"
  nohup env ROOT="$ROOT" "$ROOT/setup_odoo.sh" bootstrap >"$BOOTSTRAP_LOG" 2>&1 &
  echo "$!" >"$BOOTSTRAP_PID_FILE"
  log_info "bootstrap pid=$!"
  log_info "bootstrap log=$BOOTSTRAP_LOG"
}

# Show the status of bootstrap and Odoo processes.
status_background() {
  local bootstrap_pid odoo_pid
  bootstrap_pid="$(read_pid_file "$BOOTSTRAP_PID_FILE")"
  odoo_pid="$(read_pid_file "$ODOO_PID_FILE")"

  if pid_is_running "$bootstrap_pid"; then
    log_info "bootstrap running with pid $bootstrap_pid"
  else
    log_info "bootstrap not running"
  fi

  if pid_is_running "$odoo_pid"; then
    log_info "odoo running with pid $odoo_pid"
  else
    log_info "odoo not running"
  fi

  if command -v lsof >/dev/null 2>&1 && lsof -nP -iTCP:"$ODOO_HTTP_PORT" -sTCP:LISTEN >/dev/null 2>&1; then
    log_info "odoo is listening on port $ODOO_HTTP_PORT"
  else
    log_info "odoo is not listening on port $ODOO_HTTP_PORT"
  fi
}

# Stop both Odoo and bootstrap processes.
stop_background() {
  stop_pid_file "$ODOO_PID_FILE" "odoo"
  stop_pid_file "$BOOTSTRAP_PID_FILE" "bootstrap"
}

# Register signal handlers for graceful shutdown during bootstrap/foreground.
register_signal_handlers() {
  trap '_on_signal SIGTERM' TERM
  trap '_on_signal SIGINT' INT
  trap '_on_signal SIGHUP' HUP
}

# Internal signal handler that attempts cleanup before exiting.
_on_signal() {
  local signal="$1"
  log_warn "received $signal, initiating graceful shutdown..."
  if declare -f cleanup_bootstrap_state >/dev/null 2>&1; then
    cleanup_bootstrap_state
  fi
  if declare -f release_lock >/dev/null 2>&1; then
    release_lock
  fi
  exit 130
}
