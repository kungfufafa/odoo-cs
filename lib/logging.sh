#!/usr/bin/env bash
# ============================================================================
# logging.sh — Structured logging with levels, timestamps, and format options
# ============================================================================
# Provides log_debug, log_info, log_warn, log_error, log_fatal functions.
# Configure via:
#   LOG_LEVEL   — Minimum level to emit (DEBUG|INFO|WARN|ERROR|FATAL), default: INFO
#   LOG_FORMAT  — Output format (text|json), default: text
#   LOG_OUTPUT  — Output target (stderr|stdout|<filepath>), default: stderr
# ============================================================================

[[ -n "${_LOGGING_SH_LOADED:-}" ]] && return 0
_LOGGING_SH_LOADED=1

LOG_LEVEL="${LOG_LEVEL:-INFO}"
LOG_FORMAT="${LOG_FORMAT:-text}"
LOG_OUTPUT="${LOG_OUTPUT:-stderr}"

# Map log level names to numeric priorities for comparison.
_log_level_to_num() {
  case "$1" in
    DEBUG) echo 0 ;;
    INFO)  echo 1 ;;
    WARN)  echo 2 ;;
    ERROR) echo 3 ;;
    FATAL) echo 4 ;;
    *)     echo 1 ;;  # default to INFO for unknown levels
  esac
}

# Check if a given level should be emitted based on LOG_LEVEL threshold.
_log_should_emit() {
  local msg_level="$1"
  local threshold
  threshold="$(_log_level_to_num "$LOG_LEVEL")"
  local current
  current="$(_log_level_to_num "$msg_level")"
  (( current >= threshold ))
}

# Generate an ISO8601 timestamp for log entries.
_log_timestamp() {
  if command -v date >/dev/null 2>&1; then
    date '+%Y-%m-%dT%H:%M:%S%z' 2>/dev/null || date -u '+%Y-%m-%dT%H:%M:%SZ'
  else
    printf '%s' "$(printf '%(%Y-%m-%dT%H:%M:%S%z)T' -1 2>/dev/null || echo 'unknown')"
  fi
}

# Internal log emitter — formats and outputs the log message.
# Arguments: $1=level, $2...=message parts
_log_emit() {
  local level="$1"
  shift
  local message="$*"
  local timestamp
  timestamp="$(_log_timestamp)"

  local output
  if [[ "$LOG_FORMAT" == "json" ]]; then
    # JSON structured log output — escape special characters in message.
    local escaped_msg
    escaped_msg="$(printf '%s' "$message" | sed 's/\\/\\\\/g; s/"/\\"/g; s/\t/\\t/g')"
    output="{\"timestamp\":\"${timestamp}\",\"level\":\"${level}\",\"component\":\"setup-odoo\",\"message\":\"${escaped_msg}\"}"
  else
    # Human-readable text format with level prefix.
    output="[${timestamp}] [${level}] [setup-odoo] ${message}"
  fi

  case "$LOG_OUTPUT" in
    stderr)
      printf '%s\n' "$output" >&2
      ;;
    stdout)
      printf '%s\n' "$output"
      ;;
    *)
      # Write to file if LOG_OUTPUT is a path
      printf '%s\n' "$output" >> "$LOG_OUTPUT"
      ;;
  esac
}

# Public API — log at specific levels.
# Each function checks the threshold before emitting.

log_debug() {
  _log_should_emit "DEBUG" && _log_emit "DEBUG" "$@"
  return 0
}

log_info() {
  _log_should_emit "INFO" && _log_emit "INFO" "$@"
  return 0
}

log_warn() {
  _log_should_emit "WARN" && _log_emit "WARN" "$@"
  return 0
}

log_error() {
  _log_should_emit "ERROR" && _log_emit "ERROR" "$@"
  return 0
}

# log_fatal emits an ERROR-level message and exits with code 1.
# Use this for unrecoverable errors that should terminate the script.
log_fatal() {
  _log_emit "FATAL" "$@"
  if declare -f rollback_on_fatal >/dev/null 2>&1; then
    rollback_on_fatal 1
  fi
  exit 1
}

# Backward-compatible wrapper for the original log() function.
log() {
  log_info "$@"
}

