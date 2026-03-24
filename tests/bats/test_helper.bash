#!/usr/bin/env bash
# ============================================================================
# test_helper.bash — Shared utilities for BATS test suite
# ============================================================================
# Provides:
#   - Temporary directory setup/teardown
#   - Mock command injection via PATH
#   - Standard environment variable defaults for testing
#   - Helper functions for assertions
# ============================================================================

# Resolve paths relative to this file
TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$TEST_DIR/../.." && pwd)"
LIB_DIR="$PROJECT_ROOT/lib"

# Create an isolated temporary directory for each test
setup_test_environment() {
  export TEST_TMP
  TEST_TMP="$(mktemp -d)"
  export ROOT="$TEST_TMP"
  export MOCK_BIN="$TEST_TMP/mock_bin"
  mkdir -p "$MOCK_BIN" "$ROOT/.logs" "$ROOT/.run"

  # Set up minimal required variables to prevent errors during sourcing
  export DB_NAME="test_db"
  export DB_USER="test_user"
  export DB_PASSWORD="test_password_1234567890"
  export DB_HOST="127.0.0.1"
  export DB_PORT="5432"
  export DB_ADMIN_USER="postgres"
  export DB_ADMIN_PASSWORD=""
  export DB_ROLE_CAN_CREATEDB="1"
  export DB_ROLE_SUPERUSER="0"
  export DB_PROVISION_METHOD="auto"
  export ODOO_ADMIN_PASSWD="admin_password_12345678"
  export ODOO_HTTP_PORT="8069"
  export ODOO_GEVENT_PORT="8072"
  export ODOO_HTTP_INTERFACE="127.0.0.1"
  export ODOO_PROXY_MODE="1"
  export ODOO_LIST_DB="0"
  export ODOO_WORKERS="auto"
  export ODOO_MAX_CRON_THREADS="2"
  export ODOO_DB_MAXCONN="64"
  export ODOO_LIMIT_MEMORY_SOFT="auto"
  export ODOO_LIMIT_MEMORY_HARD="auto"
  export ODOO_LIMIT_TIME_CPU="600"
  export ODOO_LIMIT_TIME_REAL="1200"
  export ODOO_WITHOUT_DEMO="all"
  export ODOO_DBFILTER="^test_db\$"
  export DATA_DIR="$ROOT/.local/share/Odoo"
  export VENV_DIR="$ROOT/.venv"
  export LOG_FILE="$ROOT/odoo.log"
  export ARTIFACTS_DIR="$ROOT/.artifacts"
  export RESTORE_WORKDIR="$ROOT/.restore"
  export SECRETS_ENV_FILE="$ROOT/.odoo.secrets.env"
  export RUNTIME_ENV_FILE="$ROOT/.odoo_runtime.env"
  export BOOTSTRAP_LOG="$ROOT/.logs/bootstrap.log"
  export BOOTSTRAP_PID_FILE="$ROOT/.run/bootstrap.pid"
  export ODOO_STDOUT_LOG="$ROOT/.logs/odoo.stdout.log"
  export ODOO_PID_FILE="$ROOT/.run/odoo.pid"
  export LOCK_DIR="$ROOT/.run/bootstrap.lock"
  export INSTALL_MODE="auto"
  export START_AFTER_RESTORE="1"
  export RESTORE_MODE="required"
  export RESTORE_STRATEGY="refresh"
  export FILESTORE_STRATEGY="mirror"
  export ODOO_RUNTIME_AUTO_REPAIR="1"
  export ODOO_DEPENDENCY_REPAIR_RETRIES="3"
  export ODOO_DEPENDENCY_REPAIR_RETRY_DELAY="5"
  export ODOO_BIN=""
  export ODOO_SRC_DIR=""
  export ODOO_TAR_GZ=""
  export ODOO_DEB_PACKAGE=""
  export ODOO_EXE_PACKAGE=""
  export OS_FAMILY=""
  export LINUX_DISTRO=""
  export MIN_FREE_GB="20"
  export HEALTHCHECK_TIMEOUT="120"
  export BACKUP_INPUT=""
  export CUSTOM_ADDONS_DIR=""
  export ORIGINAL_DB_PASSWORD="__unset__"
  export ORIGINAL_ODOO_ADMIN_PASSWD="__unset__"

  # Suppress log output in tests unless LOG_LEVEL=DEBUG
  export LOG_LEVEL="${LOG_LEVEL:-ERROR}"
  export LOG_OUTPUT="stderr"
}

# Clean up temporary directory after each test
teardown_test_environment() {
  if [[ -n "${TEST_TMP:-}" && -d "$TEST_TMP" ]]; then
    rm -rf "$TEST_TMP"
  fi
}

# Create a mock command in MOCK_BIN that outputs the given text.
# Arguments: $1=command name, $2=output text, $3=exit code (default 0)
create_mock() {
  local cmd="$1"
  local output="${2:-}"
  local exit_code="${3:-0}"
  cat > "$MOCK_BIN/$cmd" <<MOCK_EOF
#!/usr/bin/env bash
printf '%s\n' '$output'
exit $exit_code
MOCK_EOF
  chmod +x "$MOCK_BIN/$cmd"
}

# Source a specific library module with test environment.
# Arguments: $1=module filename (e.g., "logging.sh")
load_module() {
  local module="$1"
  # Source logging first if not sourcing logging itself
  if [[ "$module" != "logging.sh" ]]; then
    # shellcheck source=/dev/null
    source "$LIB_DIR/logging.sh"
  fi
  # shellcheck source=/dev/null
  source "$LIB_DIR/$module"
}
