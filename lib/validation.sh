#!/usr/bin/env bash
# ============================================================================
# validation.sh — Input validation and sanitization for all configuration vars
# ============================================================================
# Provides validators for ports, integers, booleans, enums, paths, and
# database names. Call validate_all_inputs() during bootstrap to check
# every environment variable before proceeding.
# ============================================================================

[[ -n "${_VALIDATION_SH_LOADED:-}" ]] && return 0
_VALIDATION_SH_LOADED=1

# Validate that a value is a valid TCP port number (1–65535).
# Arguments: $1=label, $2=value
validate_port() {
  local label="$1" value="$2"
  if ! [[ "$value" =~ ^[0-9]+$ ]] || (( value < 1 || value > 65535 )); then
    log_error "$label must be a valid port (1-65535), got: '$value'"
    return 1
  fi
  return 0
}

# Validate that a value is a positive integer (>= 0).
# Arguments: $1=label, $2=value
validate_non_negative_int() {
  local label="$1" value="$2"
  if ! [[ "$value" =~ ^[0-9]+$ ]]; then
    log_error "$label must be a non-negative integer, got: '$value'"
    return 1
  fi
  return 0
}

# Validate that a value is a positive integer (> 0).
# Arguments: $1=label, $2=value
validate_positive_int() {
  local label="$1" value="$2"
  if ! [[ "$value" =~ ^[0-9]+$ ]] || (( value < 1 )); then
    log_error "$label must be a positive integer, got: '$value'"
    return 1
  fi
  return 0
}

# Validate that a value is a boolean flag (0 or 1).
# Arguments: $1=label, $2=value
validate_boolean() {
  local label="$1" value="$2"
  if [[ "$value" != "0" && "$value" != "1" ]]; then
    log_error "$label must be 0 or 1, got: '$value'"
    return 1
  fi
  return 0
}

# Validate that a value is one of the allowed enum values.
# Arguments: $1=label, $2=value, $3...=allowed values
validate_enum() {
  local label="$1" value="$2"
  shift 2
  local allowed=("$@")
  local valid=0
  for a in "${allowed[@]}"; do
    if [[ "$value" == "$a" ]]; then
      valid=1
      break
    fi
  done
  if (( valid == 0 )); then
    log_error "$label must be one of [${allowed[*]}], got: '$value'"
    return 1
  fi
  return 0
}

# Validate that a path exists on the filesystem.
# Arguments: $1=label, $2=path
validate_path_exists() {
  local label="$1" path="$2"
  if [[ ! -e "$path" ]]; then
    log_error "$label path does not exist: '$path'"
    return 1
  fi
  return 0
}

# Validate that a path is a directory.
# Arguments: $1=label, $2=path
validate_dir_exists() {
  local label="$1" path="$2"
  if [[ ! -d "$path" ]]; then
    log_error "$label directory does not exist: '$path'"
    return 1
  fi
  return 0
}

# Validate a database/role name (PostgreSQL identifier rules).
# Must start with a letter or underscore, contain only alphanumerics and underscores,
# and be at most 63 characters.
# Arguments: $1=label, $2=value
validate_db_name() {
  local label="$1" value="$2"
  if [[ -z "$value" ]]; then
    log_error "$label must not be empty"
    return 1
  fi
  if (( ${#value} > 63 )); then
    log_error "$label must be at most 63 characters, got ${#value}"
    return 1
  fi
  if ! [[ "$value" =~ ^[a-zA-Z_][a-zA-Z0-9_]*$ ]]; then
    log_error "$label must match PostgreSQL identifier rules (^[a-zA-Z_][a-zA-Z0-9_]*$), got: '$value'"
    return 1
  fi
  return 0
}

# Validate a string is a valid "auto" or positive integer value.
# This is used for ODOO_WORKERS, ODOO_LIMIT_MEMORY_SOFT, etc.
# Arguments: $1=label, $2=value
validate_auto_or_positive_int() {
  local label="$1" value="$2"
  if [[ "$value" == "auto" ]]; then
    return 0
  fi
  if ! [[ "$value" =~ ^[0-9]+$ ]]; then
    log_error "$label must be 'auto' or a non-negative integer, got: '$value'"
    return 1
  fi
  return 0
}

# Sanitize a path: resolve symlinks, remove trailing slashes.
# Arguments: $1=path
# Output: sanitized path on stdout
sanitize_path() {
  local path="$1"
  # Remove trailing slashes (but keep root /)
  path="${path%"${path##*[!/]}"}"
  [[ -z "$path" ]] && path="/"
  printf '%s\n' "$path"
}

# Validate all configuration inputs at startup.
# Logs all errors and returns 1 if any validation fails.
# This enables "fail early" with a complete error report.
validate_all_inputs() {
  local errors=0

  # Port validations
  validate_port "DB_PORT" "$DB_PORT" || (( errors++ ))
  validate_port "ODOO_HTTP_PORT" "$ODOO_HTTP_PORT" || (( errors++ ))
  validate_port "ODOO_GEVENT_PORT" "$ODOO_GEVENT_PORT" || (( errors++ ))

  # Boolean validations
  validate_boolean "DB_ROLE_CAN_CREATEDB" "$DB_ROLE_CAN_CREATEDB" || (( errors++ ))
  validate_boolean "DB_ROLE_SUPERUSER" "$DB_ROLE_SUPERUSER" || (( errors++ ))
  validate_boolean "ODOO_PROXY_MODE" "$ODOO_PROXY_MODE" || (( errors++ ))
  validate_boolean "ODOO_LIST_DB" "$ODOO_LIST_DB" || (( errors++ ))
  validate_boolean "START_AFTER_RESTORE" "$START_AFTER_RESTORE" || (( errors++ ))
  validate_boolean "ODOO_RUNTIME_AUTO_REPAIR" "$ODOO_RUNTIME_AUTO_REPAIR" || (( errors++ ))

  # Enum validations
  validate_enum "RESTORE_MODE" "$RESTORE_MODE" required auto skip || (( errors++ ))
  validate_enum "RESTORE_STRATEGY" "$RESTORE_STRATEGY" refresh reuse fail || (( errors++ ))
  validate_enum "FILESTORE_STRATEGY" "$FILESTORE_STRATEGY" mirror merge skip || (( errors++ ))
  validate_enum "DB_PROVISION_METHOD" "$DB_PROVISION_METHOD" auto sudo tcp || (( errors++ ))

  # Auto-or-int validations
  validate_auto_or_positive_int "ODOO_WORKERS" "$ODOO_WORKERS" || (( errors++ ))
  validate_auto_or_positive_int "ODOO_LIMIT_MEMORY_SOFT" "$ODOO_LIMIT_MEMORY_SOFT" || (( errors++ ))
  validate_auto_or_positive_int "ODOO_LIMIT_MEMORY_HARD" "$ODOO_LIMIT_MEMORY_HARD" || (( errors++ ))

  # Positive integer validations
  validate_positive_int "MIN_FREE_GB" "$MIN_FREE_GB" || (( errors++ ))
  validate_positive_int "HEALTHCHECK_TIMEOUT" "$HEALTHCHECK_TIMEOUT" || (( errors++ ))
  validate_positive_int "ODOO_LIMIT_TIME_CPU" "$ODOO_LIMIT_TIME_CPU" || (( errors++ ))
  validate_positive_int "ODOO_LIMIT_TIME_REAL" "$ODOO_LIMIT_TIME_REAL" || (( errors++ ))
  validate_positive_int "ODOO_DEPENDENCY_REPAIR_RETRIES" "$ODOO_DEPENDENCY_REPAIR_RETRIES" || (( errors++ ))
  validate_positive_int "ODOO_DEPENDENCY_REPAIR_RETRY_DELAY" "$ODOO_DEPENDENCY_REPAIR_RETRY_DELAY" || (( errors++ ))

  # Explicitly reject unsupported preview mode to avoid false safety assumptions
  if [[ "${DRY_RUN:-0}" != "0" ]]; then
    log_error "DRY_RUN is no longer supported; remove it and retry"
    (( errors++ ))
  fi

  # Non-negative integer validations
  validate_non_negative_int "ODOO_MAX_CRON_THREADS" "$ODOO_MAX_CRON_THREADS" || (( errors++ ))
  validate_non_negative_int "ODOO_DB_MAXCONN" "$ODOO_DB_MAXCONN" || (( errors++ ))

  # Database name validation
  validate_db_name "DB_NAME" "$DB_NAME" || (( errors++ ))
  validate_db_name "DB_USER" "$DB_USER" || (( errors++ ))

  # Path validations — only validate if explicitly set
  if [[ -n "${CUSTOM_ADDONS_DIR:-}" ]]; then
    validate_dir_exists "CUSTOM_ADDONS_DIR" "$CUSTOM_ADDONS_DIR" || (( errors++ ))
  fi

  if (( errors > 0 )); then
    log_error "input validation failed with $errors error(s)"
    return 1
  fi

  log_debug "all input validations passed"
  return 0
}
