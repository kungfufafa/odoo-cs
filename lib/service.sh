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

# Run an Odoo shell script against a database without replacing the current shell.
# Arguments: $1=database name, $2=python script file path passed via stdin
run_odoo_shell_script() {
  local db_name="$1"
  local script_file="$2"
  local odoo_conf

  [[ -f "$script_file" ]] || log_fatal "odoo shell script not found: $script_file"

  prepare_odoo_runtime
  odoo_conf="${ODOO_CONF:-$ROOT/odoo.conf}"
  [[ -f "$odoo_conf" ]] || log_fatal "odoo.conf not found at $odoo_conf — run bootstrap first"

  if [[ -n "${ODOO_BIN:-}" ]]; then
    "$ODOO_BIN" shell -c "$odoo_conf" -d "$db_name" --no-http <"$script_file"
    return $?
  fi

  [[ -n "${ODOO_SRC_DIR:-}" ]] || log_fatal "ODOO_SRC_DIR not set"
  "$VENV_DIR/bin/python" "$ODOO_SRC_DIR/setup/odoo" shell -c "$odoo_conf" -d "$db_name" --no-http <"$script_file"
}

# Start Odoo as a detached background process.
# Writes PID to ODOO_PID_FILE, redirects output to ODOO_STDOUT_LOG.
# Includes crash-detection retry: if Odoo dies within 15 seconds, show log and retry once.
# Arguments: passed through to Odoo via 'run' command
start_odoo_detached() {
  local pid max_retries=2 attempt=1
  ensure_dirs
  pid="$(read_pid_file "$ODOO_PID_FILE")"
  if pid_is_running "$pid"; then
    log_info "odoo already running with pid $pid"
    return 0
  fi

  while (( attempt <= max_retries )); do
    : >"$ODOO_STDOUT_LOG"
    nohup env ROOT="$ROOT" "$ROOT/setup_odoo.sh" run "$@" >>"$ODOO_STDOUT_LOG" 2>&1 &
    echo "$!" >"$ODOO_PID_FILE"
    local new_pid="$!"
    log_info "started Odoo pid=$new_pid (attempt $attempt/$max_retries)"
    log_info "stdout log=$ODOO_STDOUT_LOG"

    # Wait briefly and check if process is still alive
    sleep 5
    if pid_is_running "$new_pid"; then
      return 0
    fi

    log_warn "Odoo process $new_pid died within 5 seconds"

    # Show last 20 lines of log for troubleshooting
    if [[ -s "$ODOO_STDOUT_LOG" ]]; then
      log_warn "=== Last 20 lines of Odoo stdout log ==="
      tail -n 20 "$ODOO_STDOUT_LOG" | while IFS= read -r line; do
        log_warn "  $line"
      done
      log_warn "=== End of log ==="
    fi

    if [[ -s "$LOG_FILE" ]]; then
      log_warn "=== Last 20 lines of odoo.log ==="
      tail -n 20 "$LOG_FILE" | while IFS= read -r line; do
        log_warn "  $line"
      done
      log_warn "=== End of log ==="
    fi

    if (( attempt < max_retries )); then
      log_warn "retrying Odoo start..."
      sleep 3
    fi
    (( attempt++ ))
  done

  log_fatal "Odoo failed to start after $max_retries attempts — check logs: $ODOO_STDOUT_LOG and $LOG_FILE"
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
# Validates both HTTP status AND response body to ensure Odoo is truly ready.
# Also checks DB connectivity if psql is available.
# Dies if healthcheck fails after HEALTHCHECK_TIMEOUT seconds.
healthcheck_odoo() {
  local deadline url
  url="$(healthcheck_url)"
  deadline=$((SECONDS + HEALTHCHECK_TIMEOUT))

  log_info "waiting for Odoo healthcheck at $url (timeout: ${HEALTHCHECK_TIMEOUT}s)"

  local last_error="" check_count=0
  while (( SECONDS < deadline )); do
    (( check_count++ ))

    # Check if Odoo process is still alive
    local odoo_pid
    odoo_pid="$(read_pid_file "$ODOO_PID_FILE")"
    if [[ -n "$odoo_pid" ]] && ! pid_is_running "$odoo_pid"; then
      log_error "Odoo process $odoo_pid is no longer running"
      if [[ -s "$LOG_FILE" ]]; then
        log_error "Last 10 lines of odoo.log:"
        tail -n 10 "$LOG_FILE" | while IFS= read -r line; do log_error "  $line"; done
      fi
      log_fatal "Odoo process died during healthcheck — check logs: $LOG_FILE"
    fi

    if command -v curl >/dev/null 2>&1; then
      local http_code response_file
      response_file="$(mktemp 2>/dev/null || echo /tmp/odoo_hc_$$)"
      http_code="$(curl -fsS -o "$response_file" -w '%{http_code}' --max-time 10 --connect-timeout 5 "$url" 2>/dev/null || true)"

      case "$http_code" in
        200|302|303|304)
          # Verify there's actual content (not an empty/error page)
          local body_size=0
          if [[ -f "$response_file" ]]; then
            body_size=$(wc -c < "$response_file" | tr -d ' ')
          fi

          if (( body_size > 100 )); then
            log_info "healthcheck passed: $url (HTTP $http_code, ${body_size} bytes) ✓"
            rm -f "$response_file"
            return 0
          else
            last_error="HTTP $http_code but response too small (${body_size} bytes)"
          fi
          ;;
        502|503|504)
          last_error="HTTP $http_code (service starting up)"
          ;;
        *)
          last_error="HTTP $http_code"
          ;;
      esac
      rm -f "$response_file"
    elif command -v wget >/dev/null 2>&1; then
      if wget -q --spider --timeout=10 "$url" 2>/dev/null; then
        log_info "healthcheck passed: $url ✓"
        return 0
      fi
      last_error="wget failed"
    fi

    # Log progress every 30 seconds
    if (( check_count % 15 == 0 )); then
      local remaining=$(( deadline - SECONDS ))
      log_info "healthcheck still waiting... (${remaining}s remaining, last: $last_error)"
    fi

    sleep 2
  done
  log_fatal "healthcheck failed after ${HEALTHCHECK_TIMEOUT}s: $url (last: $last_error) — check logs: $LOG_FILE"
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
  if command -v systemctl >/dev/null 2>&1; then
    systemctl stop odoo-cs 2>/dev/null || true
  fi
  stop_pid_file "$ODOO_PID_FILE" "odoo"
  stop_pid_file "$BOOTSTRAP_PID_FILE" "bootstrap"
}

