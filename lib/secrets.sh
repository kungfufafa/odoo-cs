#!/usr/bin/env bash
# ============================================================================
# secrets.sh — Secure secret generation, persistence, and loading
# ============================================================================
# Manages DB_PASSWORD and ODOO_ADMIN_PASSWD:
#   - Generates cryptographically secure random secrets
#   - Persists to a chmod-600 secrets file
#   - Validates file permissions before loading
#   - Supports environment variable overrides
# ============================================================================

[[ -n "${_SECRETS_SH_LOADED:-}" ]] && return 0
_SECRETS_SH_LOADED=1

# Minimum acceptable length for generated or user-supplied secrets.
MIN_SECRET_LENGTH="${MIN_SECRET_LENGTH:-16}"

# Generate a cryptographically random secret string (32 chars, base64-safe).
# Uses openssl if available, falls back to /dev/urandom.
random_secret() {
  if command -v openssl >/dev/null 2>&1; then
    openssl rand -base64 36 | tr -d '\n' | cut -c1-32
  else
    LC_ALL=C tr -dc 'A-Za-z0-9' </dev/urandom | head -c 32
  fi
}

# Validate that the secrets file has secure permissions (600 or tighter).
# Arguments: $1=file path
# Returns 0 if permissions are acceptable, 1 otherwise.
_validate_secrets_permissions() {
  local file="$1"
  if [[ ! -f "$file" ]]; then
    return 0  # File doesn't exist yet — will be created with correct perms
  fi

  if [[ "$OS_FAMILY" == "linux" || "$OS_FAMILY" == "macos" ]]; then
    local perms
    perms="$(stat -f '%Lp' "$file" 2>/dev/null || stat -c '%a' "$file" 2>/dev/null || echo "unknown")"
    if [[ "$perms" != "unknown" && "$perms" != "600" && "$perms" != "400" ]]; then
      log_warn "secrets file $file has insecure permissions ($perms), expected 600"
      chmod 600 "$file" 2>/dev/null || true
    fi
  fi
  return 0
}

# Load persisted secrets from the secrets env file.
# Environment variable overrides take precedence over persisted values.
load_persisted_secrets() {
  if [[ -f "$SECRETS_ENV_FILE" ]]; then
    _validate_secrets_permissions "$SECRETS_ENV_FILE"
    # shellcheck disable=SC1090
    source "$SECRETS_ENV_FILE"
  fi

  # Restore original env var overrides if they were explicitly set by the user.
  if [[ "${ORIGINAL_DB_PASSWORD:-__unset__}" != "__unset__" ]]; then
    DB_PASSWORD="$ORIGINAL_DB_PASSWORD"
  fi
  if [[ "${ORIGINAL_ODOO_ADMIN_PASSWD:-__unset__}" != "__unset__" ]]; then
    ODOO_ADMIN_PASSWD="$ORIGINAL_ODOO_ADMIN_PASSWD"
  fi
}

# Write secrets to the persisted secrets file with secure permissions.
# Uses atomic write (write to temp file then mv) for crash safety.
write_secrets_file() {
  local tmp
  tmp="$(mktemp "${SECRETS_ENV_FILE}.XXXXXX")"
  {
    printf "# Auto-generated secrets — do not commit to version control\n"
    printf "DB_PASSWORD=%q\n" "$DB_PASSWORD"
    printf "ODOO_ADMIN_PASSWD=%q\n" "$ODOO_ADMIN_PASSWD"
  } >"$tmp"
  mv "$tmp" "$SECRETS_ENV_FILE"
  chmod 600 "$SECRETS_ENV_FILE"
  log_debug "secrets written to $SECRETS_ENV_FILE"
}

# Ensure that both DB_PASSWORD and ODOO_ADMIN_PASSWD are set.
# Generates random secrets for any missing values and persists them.
ensure_secrets() {
  load_persisted_secrets

  if [[ -z "$DB_PASSWORD" ]]; then
    DB_PASSWORD="$(random_secret)"
    log_info "generated DB_PASSWORD and stored it in $SECRETS_ENV_FILE"
  elif (( ${#DB_PASSWORD} < MIN_SECRET_LENGTH )); then
    log_warn "DB_PASSWORD is shorter than $MIN_SECRET_LENGTH characters — consider using a stronger password"
  fi

  if [[ -z "$ODOO_ADMIN_PASSWD" ]]; then
    ODOO_ADMIN_PASSWD="$(random_secret)"
    log_info "generated ODOO_ADMIN_PASSWD and stored it in $SECRETS_ENV_FILE"
  elif (( ${#ODOO_ADMIN_PASSWD} < MIN_SECRET_LENGTH )); then
    log_warn "ODOO_ADMIN_PASSWD is shorter than $MIN_SECRET_LENGTH characters — consider using a stronger password"
  fi

  write_secrets_file
}
