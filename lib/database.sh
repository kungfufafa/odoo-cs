#!/usr/bin/env bash
# ============================================================================
# database.sh — PostgreSQL role and database management
# ============================================================================
# Handles: DB role creation, database creation/drop, connection testing,
# admin SQL execution, and SQL escaping utilities.
# Supports both sudo (local socket) and TCP connection methods.
# ============================================================================

[[ -n "${_DATABASE_SH_LOADED:-}" ]] && return 0
_DATABASE_SH_LOADED=1

# Number of retry attempts for database connections.
DB_CONNECT_RETRIES="${DB_CONNECT_RETRIES:-3}"
DB_CONNECT_RETRY_DELAY="${DB_CONNECT_RETRY_DELAY:-5}"

# Escape a string for use as a SQL literal (double single-quotes).
# Arguments: $1=string
# Output: escaped string on stdout
sql_escape_literal() {
  printf "%s" "$1" | sed "s/'/''/g"
}

# Quote an identifier for use in SQL (double double-quotes, wrap in quotes).
# Arguments: $1=identifier
# Output: quoted identifier on stdout
sql_quote_ident() {
  local value="$1"
  value="${value//\"/\"\"}"
  printf '"%s"' "$value"
}

# Determine whether DB_HOST still points to the local PostgreSQL instance.
# Returns 0 for local loopback or a Unix socket directory, 1 otherwise.
db_host_is_local() {
  case "${DB_HOST:-}" in
    ""|localhost|127.0.0.1|::1)
      return 0
      ;;
    /*)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

# Determine whether to use the local postgres OS user path for admin operations.
# Returns 0 (true) for local socket/peer access, 1 otherwise.
should_use_sudo_for_db() {
  [[ "$DB_PROVISION_METHOD" == "sudo" ]] && return 0
  [[ "$DB_PROVISION_METHOD" != "auto" ]] && return 1
  [[ "$OS_FAMILY" == "linux" ]] || return 1
  [[ "$LINUX_DISTRO" == "ubuntu" || "$LINUX_DISTRO" == "debian" ]] || return 1
  [[ "$DB_ADMIN_USER" == "postgres" ]] || return 1
  db_host_is_local || return 1
  if is_root_user; then
    command -v runuser >/dev/null 2>&1 || command -v su >/dev/null 2>&1 || return 1
    return 0
  fi
  command -v sudo >/dev/null 2>&1 || return 1
  if shell_has_tty; then
    return 0
  fi
  sudo_can_run_noninteractive || return 1
  return 0
}

# Resolve the host to use for TCP-based admin connections.
# Local socket paths are normalized to loopback so the fallback is real TCP.
# Output: host value on stdout
resolve_tcp_db_admin_host() {
  case "${DB_HOST:-}" in
    ""|/*)
      printf '127.0.0.1\n'
      ;;
    *)
      printf '%s\n' "$DB_HOST"
      ;;
  esac
}

# Execute a command as the local postgres OS user.
# Uses root-native user switching when already root, otherwise falls back to sudo.
run_local_postgres_command() {
  if is_root_user; then
    if command -v runuser >/dev/null 2>&1; then
      runuser -u postgres -- "$@"
      return $?
    fi
    if command -v su >/dev/null 2>&1; then
      local command_string
      printf -v command_string '%q ' "$@"
      su -s /bin/bash postgres -c "$command_string"
      return $?
    fi
    log_fatal "required command not found: runuser or su"
  fi

  require_cmd sudo
  if shell_has_tty; then
    sudo -u postgres "$@"
    return $?
  fi

  if sudo_can_run_noninteractive; then
    sudo -n -u postgres "$@"
    return $?
  fi

  log_fatal "PostgreSQL admin access requires sudo but no terminal is available — rerun './setup_odoo.sh bootstrap' in an interactive shell, configure passwordless sudo, or set DB_PROVISION_METHOD=tcp with DB_ADMIN_PASSWORD"
}

# Execute a SQL statement as the database admin user using psql.
# Uses sudo or TCP depending on should_use_sudo_for_db().
# Arguments: $1=SQL statement
# Output: query result on stdout
run_admin_psql() {
  local sql="$1"
  local tcp_host
  require_cmd psql

  if should_use_sudo_for_db; then
    if [[ "${DB_HOST:-}" == /* ]]; then
      run_local_postgres_command psql -v ON_ERROR_STOP=1 -h "$DB_HOST" -p "$DB_PORT" -d postgres -Atqc "$sql"
    else
      run_local_postgres_command psql -v ON_ERROR_STOP=1 -p "$DB_PORT" -d postgres -Atqc "$sql"
    fi
  else
    tcp_host="$(resolve_tcp_db_admin_host)"
    PGPASSWORD="$DB_ADMIN_PASSWORD" psql -h "$tcp_host" -p "$DB_PORT" -U "$DB_ADMIN_USER" -d postgres -v ON_ERROR_STOP=1 -Atqc "$sql"
  fi
}

# Execute a SQL statement against the restored application database.
# Arguments: $1=SQL statement, $2=target database (optional, defaults to DB_NAME)
# Output: query result on stdout
run_target_psql() {
  local sql="$1"
  local target_db="${2:-$DB_NAME}"
  require_cmd psql

  PGPASSWORD="$DB_PASSWORD" psql -h "$DB_HOST" -p "$DB_PORT" -U "$DB_USER" -d "$target_db" -v ON_ERROR_STOP=1 -Atqc "$sql"
}

# Test database connectivity with retry logic.
# Returns 0 if connection succeeds, 1 after exhausting retries.
test_db_connection() {
  local attempt=1
  while (( attempt <= DB_CONNECT_RETRIES )); do
    if run_admin_psql "SELECT 1;" >/dev/null 2>&1; then
      log_debug "database connection successful (attempt $attempt)"
      return 0
    fi
    log_warn "database connection attempt $attempt/$DB_CONNECT_RETRIES failed, retrying in ${DB_CONNECT_RETRY_DELAY}s..."
    sleep "$DB_CONNECT_RETRY_DELAY"
    (( attempt++ ))
  done
  if [[ "$DB_PROVISION_METHOD" == "auto" ]] &&
     [[ "$OS_FAMILY" == "linux" ]] &&
     [[ "$LINUX_DISTRO" == "ubuntu" || "$LINUX_DISTRO" == "debian" ]] &&
     [[ "$DB_ADMIN_USER" == "postgres" ]] &&
     db_host_is_local &&
     ! is_root_user &&
     ! shell_has_tty &&
     command -v sudo >/dev/null 2>&1 &&
     ! sudo_can_run_noninteractive; then
    if [[ -n "${DB_ADMIN_PASSWORD:-}" ]]; then
      log_error "auto DB provisioning skipped local sudo because no terminal/passwordless sudo was available; verify DB_ADMIN_PASSWORD for TCP admin access"
    else
      log_error "auto DB provisioning cannot use local sudo without a terminal; rerun interactively, configure passwordless sudo, or set DB_PROVISION_METHOD=tcp with DB_ADMIN_PASSWORD"
    fi
  fi
  log_error "unable to connect to PostgreSQL after $DB_CONNECT_RETRIES attempts"
  return 1
}

# Check if a database with the given name exists.
# Arguments: $1=database name
# Returns 0 if exists, 1 otherwise.
db_exists_named() {
  local db_name="$1"
  local sql output
  sql="SELECT 1 FROM pg_database WHERE datname = '$(sql_escape_literal "$db_name")';"
  output="$(run_admin_psql "$sql" || true)"
  [[ "$output" == "1" ]]
}

# Check if the configured target database exists.
# Returns 0 if exists, 1 otherwise.
db_exists() {
  db_exists_named "$DB_NAME"
}

# Terminate all active connections to the given database.
# Arguments: $1=database name
# Silently ignores errors (connections may already be gone).
terminate_db_connections_named() {
  local db_name="$1"
  local db_lit sql
  db_lit="$(sql_escape_literal "$db_name")"
  sql="SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname = '$db_lit' AND pid <> pg_backend_pid();"
  run_admin_psql "$sql" >/dev/null || true
}


# Create the given database if it does not already exist.
# Arguments: $1=database name, $2=owner role
# Sets ownership to DB_USER with UTF8 encoding.
create_database_named_if_missing() {
  local db_name="$1"
  local db_owner="$2"
  local db_ident user_ident sql
  db_ident="$(sql_quote_ident "$db_name")"
  user_ident="$(sql_quote_ident "$db_owner")"

  if db_exists_named "$db_name"; then
    log_debug "database $db_name already exists"
    return 0
  fi

  log_info "creating database: $db_name"
  sql="CREATE DATABASE $db_ident OWNER $user_ident TEMPLATE template0 ENCODING 'UTF8';"
  run_admin_psql "$sql" >/dev/null
}

# Create the configured target database if it does not already exist.
# Sets ownership to DB_USER with UTF8 encoding.
create_database_if_needed() {
  create_database_named_if_missing "$DB_NAME" "$DB_USER"
}

# Drop the given database if it exists.
# Arguments: $1=database name
# Terminates active connections first.
drop_database_named_if_exists() {
  local db_name="$1"
  local db_ident sql
  db_ident="$(sql_quote_ident "$db_name")"
  if db_exists_named "$db_name"; then
    log_info "dropping database: $db_name"
    terminate_db_connections_named "$db_name"
    sql="DROP DATABASE IF EXISTS $db_ident;"
    run_admin_psql "$sql" >/dev/null
  fi
}

# Drop the configured target database if it exists.
# Terminates active connections first.
drop_database_if_exists() {
  drop_database_named_if_exists "$DB_NAME"
}

# Rename a database after terminating active connections.
# Arguments: $1=current name, $2=new name
rename_database() {
  local current_name="$1"
  local new_name="$2"
  local current_ident new_ident sql
  current_ident="$(sql_quote_ident "$current_name")"
  new_ident="$(sql_quote_ident "$new_name")"

  log_info "renaming database: $current_name -> $new_name"
  terminate_db_connections_named "$current_name"
  sql="ALTER DATABASE $current_ident RENAME TO $new_ident;"
  run_admin_psql "$sql" >/dev/null
}

# Ensure the DB_USER role exists with the correct password and privileges.
# Creates the role if missing, or alters it if it already exists.
ensure_db_role() {
  local user_ident password_lit role_flags sql
  user_ident="$(sql_quote_ident "$DB_USER")"
  password_lit="$(sql_escape_literal "$DB_PASSWORD")"
  role_flags="LOGIN NOCREATEROLE NOBYPASSRLS"

  if [[ "$DB_ROLE_CAN_CREATEDB" == "1" ]]; then
    role_flags="$role_flags CREATEDB"
  else
    role_flags="$role_flags NOCREATEDB"
  fi

  if [[ "$DB_ROLE_SUPERUSER" == "1" ]]; then
    role_flags="$role_flags SUPERUSER"
  else
    role_flags="$role_flags NOSUPERUSER"
  fi

  log_info "ensuring PostgreSQL role exists"
  sql="
DO \$\$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = '$(sql_escape_literal "$DB_USER")') THEN
    CREATE ROLE $user_ident $role_flags PASSWORD '$password_lit';
  ELSE
    ALTER ROLE $user_ident WITH $role_flags PASSWORD '$password_lit';
  END IF;
END
\$\$;
"
  run_admin_psql "$sql" >/dev/null
}

# Ensure pg_hba.conf allows md5/scram-sha-256 authentication for TCP connections.
# Without this, a fresh PostgreSQL install only has peer auth and will reject
# password-based logins from Odoo.
ensure_pg_hba_md5() {
  [[ "$OS_FAMILY" == "linux" ]] || return 0
  [[ "$LINUX_DISTRO" == "ubuntu" || "$LINUX_DISTRO" == "debian" ]] || return 0

  local pg_hba pg_version_dir pg_version
  local need_reload=0

  # Find pg_hba.conf — try common paths
  for pg_version_dir in /etc/postgresql/*/main; do
    [[ -d "$pg_version_dir" ]] || continue
    pg_hba="$pg_version_dir/pg_hba.conf"
    [[ -f "$pg_hba" ]] && break
    pg_hba=""
  done

  if [[ -z "${pg_hba:-}" ]]; then
    log_debug "pg_hba.conf not found in standard locations, skipping auto-fix"
    return 0
  fi

  log_debug "checking pg_hba.conf at $pg_hba"

  # Check if there's already a host line for 127.0.0.1 with md5/scram-sha-256
  if grep -Eq '^host[[:space:]]+all[[:space:]]+all[[:space:]]+127\.0\.0\.1/32[[:space:]]+(md5|scram-sha-256)' "$pg_hba" 2>/dev/null; then
    log_debug "pg_hba.conf already has md5/scram-sha-256 for 127.0.0.1"
    return 0
  fi

  log_info "Adding md5 auth entry to pg_hba.conf for TCP connections"
  # Add before the first 'local' line to ensure it takes precedence
  {
    printf '# Added by setup_odoo.sh for Odoo TCP auth\n'
    printf 'host    all             all             127.0.0.1/32            md5\n'
    printf 'host    all             all             ::1/128                 md5\n'
  } | run_privileged tee -a "$pg_hba" >/dev/null

  need_reload=1

  if (( need_reload )); then
    log_info "Reloading PostgreSQL after pg_hba.conf update"
    run_privileged systemctl reload postgresql 2>/dev/null || \
    run_privileged systemctl restart postgresql 2>/dev/null || true
  fi
}

# Ensure PostgreSQL is running on Linux systems.
# On Ubuntu/Debian, enables and restarts the postgresql service,
# then ensures pg_hba.conf allows md5 auth.
ensure_postgres_running() {
  [[ "$OS_FAMILY" == "linux" ]] || return 0
  if [[ "$LINUX_DISTRO" == "ubuntu" || "$LINUX_DISTRO" == "debian" ]]; then
    log_info "starting PostgreSQL"
    run_privileged systemctl enable postgresql >/dev/null 2>&1 || true
    run_privileged systemctl restart postgresql
    ensure_pg_hba_md5
  fi
}
