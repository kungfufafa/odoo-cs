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

# Determine whether to use sudo for PostgreSQL admin operations.
# Returns 0 (true) if sudo should be used, 1 otherwise.
should_use_sudo_for_db() {
  [[ "$DB_PROVISION_METHOD" == "sudo" ]] && return 0
  [[ "$DB_PROVISION_METHOD" != "auto" ]] && return 1
  [[ "$OS_FAMILY" == "linux" ]] || return 1
  [[ "$LINUX_DISTRO" == "ubuntu" || "$LINUX_DISTRO" == "debian" ]] || return 1
  [[ "$DB_ADMIN_USER" == "postgres" ]] || return 1
  db_host_is_local || return 1
  command -v sudo >/dev/null 2>&1 || return 1
  return 0
}

# Execute a SQL statement as the database admin user using psql.
# Uses sudo or TCP depending on should_use_sudo_for_db().
# Arguments: $1=SQL statement
# Output: query result on stdout
run_admin_psql() {
  local sql="$1"
  require_cmd psql

  if should_use_sudo_for_db; then
    if [[ "${DB_HOST:-}" == /* ]]; then
      sudo -u postgres psql -v ON_ERROR_STOP=1 -h "$DB_HOST" -p "$DB_PORT" -d postgres -Atqc "$sql"
    else
      sudo -u postgres psql -v ON_ERROR_STOP=1 -p "$DB_PORT" -d postgres -Atqc "$sql"
    fi
  else
    PGPASSWORD="$DB_ADMIN_PASSWORD" psql -h "$DB_HOST" -p "$DB_PORT" -U "$DB_ADMIN_USER" -d postgres -v ON_ERROR_STOP=1 -Atqc "$sql"
  fi
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

# Terminate all active connections to the configured target database.
# Silently ignores errors (connections may already be gone).
terminate_db_connections() {
  terminate_db_connections_named "$DB_NAME"
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

# Ensure PostgreSQL is running on Linux systems.
# On Ubuntu/Debian, enables and restarts the postgresql service.
ensure_postgres_running() {
  [[ "$OS_FAMILY" == "linux" ]] || return 0
  if [[ "$LINUX_DISTRO" == "ubuntu" || "$LINUX_DISTRO" == "debian" ]]; then
    require_cmd sudo
    log_info "starting PostgreSQL"
    sudo systemctl enable postgresql >/dev/null 2>&1 || true
    sudo systemctl restart postgresql
  fi
}
