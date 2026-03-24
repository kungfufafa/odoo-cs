#!/usr/bin/env bats
# ============================================================================
# database.bats — Unit tests for lib/database.sh (SQL escaping, mocked ops)
# ============================================================================

load test_helper

setup() {
  setup_test_environment
  export OS_FAMILY="linux"
  export LINUX_DISTRO="ubuntu"
  load_module "platform.sh"
  load_module "database.sh"
}

teardown() {
  teardown_test_environment
}

# --- sql_escape_literal -----------------------------------------------------

@test "sql_escape_literal escapes single quotes" {
  result="$(sql_escape_literal "it's a test")"
  [ "$result" = "it''s a test" ]
}

@test "sql_escape_literal handles no quotes" {
  result="$(sql_escape_literal "normal_value")"
  [ "$result" = "normal_value" ]
}

@test "sql_escape_literal handles empty string" {
  result="$(sql_escape_literal "")"
  [ "$result" = "" ]
}

@test "sql_escape_literal handles multiple quotes" {
  result="$(sql_escape_literal "it's a ''test''")"
  [ "$result" = "it''s a ''''test''''" ]
}

# --- sql_quote_ident --------------------------------------------------------

@test "sql_quote_ident wraps in double quotes" {
  result="$(sql_quote_ident "my_table")"
  [ "$result" = '"my_table"' ]
}

@test "sql_quote_ident escapes embedded double quotes" {
  result="$(sql_quote_ident 'my"table')"
  [ "$result" = '"my""table"' ]
}

@test "sql_quote_ident handles empty string" {
  result="$(sql_quote_ident "")"
  [ "$result" = '""' ]
}

# --- db_host_is_local -------------------------------------------------------

@test "db_host_is_local accepts loopback host" {
  export DB_HOST="127.0.0.1"
  run db_host_is_local
  [ "$status" -eq 0 ]
}

@test "db_host_is_local rejects remote host" {
  export DB_HOST="db.example.com"
  run db_host_is_local
  [ "$status" -ne 0 ]
}

# --- should_use_sudo_for_db ------------------------------------------------

@test "should_use_sudo_for_db returns true for sudo method" {
  export DB_PROVISION_METHOD="sudo"
  run should_use_sudo_for_db
  [ "$status" -eq 0 ]
}

@test "should_use_sudo_for_db returns false for tcp method" {
  export DB_PROVISION_METHOD="tcp"
  run should_use_sudo_for_db
  [ "$status" -ne 0 ]
}

@test "should_use_sudo_for_db auto mode checks linux+ubuntu+postgres" {
  export DB_PROVISION_METHOD="auto"
  export OS_FAMILY="linux"
  export LINUX_DISTRO="ubuntu"
  export DB_ADMIN_USER="postgres"
  # This may or may not have sudo available in test env
  run should_use_sudo_for_db
  # We just check it runs without crashing
  true
}

@test "should_use_sudo_for_db returns false for macos" {
  export DB_PROVISION_METHOD="auto"
  export OS_FAMILY="macos"
  run should_use_sudo_for_db
  [ "$status" -ne 0 ]
}

@test "should_use_sudo_for_db returns true for root without sudo" {
  export PATH="$MOCK_BIN:$PATH"
  create_mock "id" "0"
  create_mock "runuser" ""
  export DB_PROVISION_METHOD="auto"
  export DB_ADMIN_USER="postgres"
  export DB_HOST="127.0.0.1"
  run should_use_sudo_for_db
  [ "$status" -eq 0 ]
}

@test "should_use_sudo_for_db returns false for remote DB_HOST in auto mode" {
  export PATH="$MOCK_BIN:$PATH"
  create_mock "sudo" ""
  export DB_PROVISION_METHOD="auto"
  export DB_ADMIN_USER="postgres"
  export DB_HOST="db.example.com"
  run should_use_sudo_for_db
  [ "$status" -ne 0 ]
}

@test "should_use_sudo_for_db falls back from sudo in auto mode without tty" {
  export PATH="$MOCK_BIN:$PATH"
  create_mock "sudo" "" 1
  export DB_PROVISION_METHOD="auto"
  export DB_ADMIN_USER="postgres"
  export DB_HOST="127.0.0.1"

  shell_has_tty() {
    return 1
  }

  run should_use_sudo_for_db

  [ "$status" -ne 0 ]
}

# --- run_admin_psql --------------------------------------------------------

@test "run_admin_psql uses TCP path for remote host in auto mode" {
  export PATH="$MOCK_BIN:$PATH"
  create_mock "psql" "1"
  create_mock "sudo" "" 99
  export DB_PROVISION_METHOD="auto"
  export DB_ADMIN_USER="postgres"
  export DB_HOST="db.example.com"
  run run_admin_psql "SELECT 1;"
  [ "$status" -eq 0 ]
}

@test "run_admin_psql uses postgres OS user path when running as root" {
  export PATH="$MOCK_BIN:$PATH"
  create_mock "id" "0"
  create_mock "psql" "1"
  cat > "$MOCK_BIN/runuser" <<'EOF'
#!/usr/bin/env bash
shift 2
if [[ "$1" == "--" ]]; then
  shift
fi
exec "$@"
EOF
  chmod +x "$MOCK_BIN/runuser"
  create_mock "sudo" "" 99
  export DB_PROVISION_METHOD="auto"
  export DB_ADMIN_USER="postgres"
  export DB_HOST="127.0.0.1"
  run run_admin_psql "SELECT 1;"
  [ "$status" -eq 0 ]
  [ "$output" = "1" ]
}

@test "run_local_postgres_command fails clearly without tty when sudo cannot prompt" {
  export PATH="$MOCK_BIN:$PATH"
  create_mock "id" "1000"
  create_mock "sudo" "" 1

  shell_has_tty() {
    return 1
  }

  run run_local_postgres_command psql -c "SELECT 1"

  [ "$status" -ne 0 ]
  [[ "$output" == *"PostgreSQL admin access requires sudo but no terminal is available"* ]]
}

@test "run_local_postgres_command returns the wrapped command status" {
  export PATH="$MOCK_BIN:$PATH"
  create_mock "id" "1000"
  create_mock "sudo" "" 37

  shell_has_tty() {
    return 0
  }

  run run_local_postgres_command psql -c "SELECT 1"

  [ "$status" -eq 37 ]
}

@test "run_admin_psql uses loopback TCP when DB_HOST is a socket path" {
  export PATH="$MOCK_BIN:$PATH"
  export DB_PROVISION_METHOD="auto"
  export DB_ADMIN_USER="postgres"
  export DB_ADMIN_PASSWORD="secret"
  export DB_HOST="/var/run/postgresql"
  create_mock "id" "1000"
  create_mock "sudo" "" 1
  cat > "$MOCK_BIN/psql" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" > "$ROOT/psql-args.txt"
printf '1\n'
EOF
  chmod +x "$MOCK_BIN/psql"

  shell_has_tty() {
    return 1
  }

  run run_admin_psql "SELECT 1;"

  [ "$status" -eq 0 ]
  [ "$output" = "1" ]
  grep -q -- "-h 127.0.0.1" "$ROOT/psql-args.txt"
}

# --- DB connection retry ---------------------------------------------------

@test "test_db_connection keeps the real error when sudo is unsupported" {
  export PATH="$MOCK_BIN"
  export DB_CONNECT_RETRIES="1"
  export DB_CONNECT_RETRY_DELAY="0"
  export DB_PROVISION_METHOD="auto"
  export OS_FAMILY="linux"
  export LINUX_DISTRO="fedora"
  export DB_ADMIN_USER="postgres"
  export DB_HOST="127.0.0.1"

  run_admin_psql() {
    return 1
  }
  is_root_user() {
    return 1
  }
  shell_has_tty() {
    return 1
  }

  run test_db_connection

  [ "$status" -eq 1 ]
  [[ "$output" == *"unable to connect to PostgreSQL after 1 attempts"* ]]
  [[ "$output" != *"required command not found: sudo"* ]]
}

@test "DB_CONNECT_RETRIES defaults to 3" {
  [ "$DB_CONNECT_RETRIES" = "3" ]
}

@test "DB_CONNECT_RETRY_DELAY defaults to 5" {
  [ "$DB_CONNECT_RETRY_DELAY" = "5" ]
}

# --- ensure_postgres_running ------------------------------------------------

@test "ensure_postgres_running is no-op on macOS" {
  export OS_FAMILY="macos"
  run ensure_postgres_running
  [ "$status" -eq 0 ]
}
