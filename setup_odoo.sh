#!/usr/bin/env bash
# ============================================================================
# setup_odoo.sh — Production-ready Odoo 16.0e Setup & Management Script
# ============================================================================
# One-command Odoo deployment: extracts artifacts, provisions PostgreSQL,
# restores database backups, and manages the Odoo service lifecycle.
#
# Usage:
#   ./setup_odoo.sh start       — Bootstrap in background + start Odoo
#   ./setup_odoo.sh bootstrap   — Bootstrap in foreground + start Odoo detached
#   ./setup_odoo.sh foreground  — Bootstrap in foreground + run Odoo attached
#   ./setup_odoo.sh run         — Start Odoo using last runtime env
#   ./setup_odoo.sh status      — Show process and port status
#   ./setup_odoo.sh logs        — Follow bootstrap log
#   ./setup_odoo.sh stop        — Stop Odoo and bootstrap processes
#   ./setup_odoo.sh --version   — Show script version
#   ./setup_odoo.sh help        — Show full usage information
#
# See README.md for full documentation, or run with 'help' for env overrides.
# ============================================================================
set -Eeuo pipefail
umask 077

# ============================================================================
# Root directory and CLI argument parsing
# ============================================================================
ROOT="${ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}"
CMD="${1:-start}"
if [[ $# -gt 0 ]]; then
  shift
fi

# ============================================================================
# Load modular library (or show helpful error)
# ============================================================================
LIB_DIR="$ROOT/lib"
if [[ -d "$LIB_DIR" && -f "$LIB_DIR/_bootstrap.sh" ]]; then
  # Preserve original env var values before anything else overrides them
  ORIGINAL_DB_PASSWORD="${DB_PASSWORD-__unset__}"
  ORIGINAL_ODOO_ADMIN_PASSWD="${ODOO_ADMIN_PASSWD-__unset__}"

  # -- Default configuration values ------------------------------------------
  # These can all be overridden via environment variables.
  ODOO_SRC_DIR="${ODOO_SRC_DIR:-}"
  CUSTOM_ADDONS_DIR="${CUSTOM_ADDONS_DIR:-}"
  BACKUP_INPUT="${BACKUP_INPUT:-}"
  ODOO_DEB_PACKAGE="${ODOO_DEB_PACKAGE:-}"
  ODOO_EXE_PACKAGE="${ODOO_EXE_PACKAGE:-}"
  ODOO_TAR_GZ="${ODOO_TAR_GZ:-}"
  DB_NAME="${DB_NAME:-mkli_local}"
  DB_USER="${DB_USER:-odoo}"
  DB_PASSWORD="${DB_PASSWORD:-}"
  DB_HOST="${DB_HOST:-127.0.0.1}"
  DB_PORT="${DB_PORT:-5432}"
  DB_ADMIN_USER="${DB_ADMIN_USER:-postgres}"
  DB_ADMIN_PASSWORD="${DB_ADMIN_PASSWORD:-}"
  DB_ROLE_CAN_CREATEDB="${DB_ROLE_CAN_CREATEDB:-1}"
  DB_ROLE_SUPERUSER="${DB_ROLE_SUPERUSER:-0}"
  DB_PROVISION_METHOD="${DB_PROVISION_METHOD:-auto}"
  ODOO_ADMIN_PASSWD="${ODOO_ADMIN_PASSWD:-}"
  ODOO_HTTP_PORT="${ODOO_HTTP_PORT:-8069}"
  ODOO_GEVENT_PORT="${ODOO_GEVENT_PORT:-8072}"
  ODOO_HTTP_INTERFACE="${ODOO_HTTP_INTERFACE:-127.0.0.1}"
  ODOO_PROXY_MODE="${ODOO_PROXY_MODE:-1}"
  ODOO_LIST_DB="${ODOO_LIST_DB:-0}"
  ODOO_WORKERS="${ODOO_WORKERS:-auto}"
  ODOO_MAX_CRON_THREADS="${ODOO_MAX_CRON_THREADS:-2}"
  ODOO_DB_MAXCONN="${ODOO_DB_MAXCONN:-64}"
  ODOO_LIMIT_MEMORY_SOFT="${ODOO_LIMIT_MEMORY_SOFT:-auto}"
  ODOO_LIMIT_MEMORY_HARD="${ODOO_LIMIT_MEMORY_HARD:-auto}"
  ODOO_LIMIT_TIME_CPU="${ODOO_LIMIT_TIME_CPU:-600}"
  ODOO_LIMIT_TIME_REAL="${ODOO_LIMIT_TIME_REAL:-1200}"
  ODOO_WITHOUT_DEMO="${ODOO_WITHOUT_DEMO:-all}"
  ODOO_DBFILTER="${ODOO_DBFILTER:-^${DB_NAME}$}"
  DATA_DIR="${DATA_DIR:-$ROOT/.local/share/Odoo}"
  VENV_DIR="${VENV_DIR:-$ROOT/.venv}"
  LOG_FILE="${LOG_FILE:-$ROOT/odoo.log}"
  ARTIFACTS_DIR="${ARTIFACTS_DIR:-$ROOT/.artifacts}"
  RESTORE_WORKDIR="${RESTORE_WORKDIR:-$ROOT/.restore}"
  SECRETS_ENV_FILE="${SECRETS_ENV_FILE:-$ROOT/.odoo.secrets.env}"
  RUNTIME_ENV_FILE="${RUNTIME_ENV_FILE:-$ROOT/.odoo_runtime.env}"
  BOOTSTRAP_LOG="${BOOTSTRAP_LOG:-$ROOT/.logs/bootstrap.log}"
  BOOTSTRAP_PID_FILE="${BOOTSTRAP_PID_FILE:-$ROOT/.run/bootstrap.pid}"
  ODOO_STDOUT_LOG="${ODOO_STDOUT_LOG:-$ROOT/.logs/odoo.stdout.log}"
  ODOO_PID_FILE="${ODOO_PID_FILE:-$ROOT/.run/odoo.pid}"
  LOCK_DIR="${LOCK_DIR:-$ROOT/.run/bootstrap.lock}"
  INSTALL_MODE="${INSTALL_MODE:-auto}"
  START_AFTER_RESTORE="${START_AFTER_RESTORE:-1}"
  RESTORE_MODE="${RESTORE_MODE:-required}"
  RESTORE_STRATEGY="${RESTORE_STRATEGY:-refresh}"
  FILESTORE_STRATEGY="${FILESTORE_STRATEGY:-mirror}"
  ODOO_BIN="${ODOO_BIN:-}"
  OS_FAMILY="${OS_FAMILY:-}"
  LINUX_DISTRO="${LINUX_DISTRO:-}"
  MIN_FREE_GB="${MIN_FREE_GB:-20}"
  HEALTHCHECK_TIMEOUT="${HEALTHCHECK_TIMEOUT:-120}"

  # Source all library modules
  # shellcheck source=lib/_bootstrap.sh
  source "$LIB_DIR/_bootstrap.sh"
else
  printf '[setup-odoo] ERROR: lib/ directory not found at %s\n' "$LIB_DIR" >&2
  printf '[setup-odoo] Please ensure the lib/ directory is alongside setup_odoo.sh\n' >&2
  exit 1
fi

# ============================================================================
# CLI usage display
# ============================================================================
usage() {
  cat <<'EOF'
Usage:
  ./setup_odoo.sh start
  ./setup_odoo.sh bootstrap
  ./setup_odoo.sh foreground
  ./setup_odoo.sh run [-d <db_name>]
  ./setup_odoo.sh status
  ./setup_odoo.sh logs
  ./setup_odoo.sh stop
  ./setup_odoo.sh --version
  ./setup_odoo.sh help

Commands:
  start       Run bootstrap in background, then start Odoo detached.
  bootstrap   Run bootstrap once in the current shell and start Odoo detached.
  foreground  Run bootstrap once in the current shell and then exec Odoo attached.
  run         Run Odoo immediately using the last generated runtime files.
  status      Show bootstrap/Odoo PID and port status.
  logs        Follow bootstrap log.
  stop        Stop only the Odoo/bootstrap PIDs created by this script.
  --version   Show script version and exit.

Environment overrides:
  DB_NAME, DB_USER, DB_PASSWORD, DB_HOST, DB_PORT
  DB_ADMIN_USER, DB_ADMIN_PASSWORD
  DB_ROLE_CAN_CREATEDB=0|1       DB_ROLE_SUPERUSER=0|1
  DB_PROVISION_METHOD=auto|sudo|tcp
  DB_CONNECT_RETRIES=3            DB_CONNECT_RETRY_DELAY=5
  BACKUP_INPUT
  RESTORE_MODE=required|auto|skip
  RESTORE_STRATEGY=refresh|reuse|fail
  FILESTORE_STRATEGY=mirror|merge|skip
  CUSTOM_ADDONS_DIR               CUSTOM_ADDONS_ZIP_PATTERNS
  ODOO_TAR_GZ, ODOO_DEB_PACKAGE, ODOO_EXE_PACKAGE
  ODOO_HTTP_PORT, ODOO_GEVENT_PORT, ODOO_HTTP_INTERFACE
  ODOO_ADMIN_PASSWD               ODOO_PACKAGE_SHA256
  ODOO_PROXY_MODE=0|1             ODOO_LIST_DB=0|1
  ODOO_WORKERS=<n>|auto
  START_AFTER_RESTORE=0|1
  MIN_FREE_GB                     HEALTHCHECK_TIMEOUT
  LOG_LEVEL=DEBUG|INFO|WARN|ERROR LOG_FORMAT=text|json
  STOP_TIMEOUT=30
EOF
}

# ============================================================================
# Bootstrap orchestration
# ============================================================================

# Full environment preparation: validates inputs, detects platform, provisions
# database, installs Odoo, generates config, and restores backup.
prepare_environment() {
  local mode

  ensure_dirs
  acquire_lock
  detect_platform
  [[ "$OS_FAMILY" != "windows" ]] || log_fatal "use setup_odoo.ps1 on Windows"

  # Validate all inputs early to fail fast with clear messages
  validate_all_inputs || log_fatal "input validation failed — fix the above errors and retry"

  # Initialize rollback system for automatic cleanup on failure
  rollback_init

  ensure_secrets
  check_memory_hint
  check_free_space

  # Determine installation mode and resolve artifacts
  mode="$(resolve_install_mode)"
  INSTALL_MODE="$mode"

  case "$mode" in
    source)
      ODOO_SRC_DIR="$(detect_odoo_src_from_existing || true)"
      [[ -n "$ODOO_SRC_DIR" ]] || extract_odoo_tarball
      ;;
    deb) ;;
    exe) ;;
    *)
      log_fatal "unsupported install mode: $mode"
      ;;
  esac

  CUSTOM_ADDONS_DIR="$(detect_custom_addons)"
  show_selected_artifacts

  # Install system dependencies and set up database
  install_linux_packages_if_needed
  ensure_postgres_running

  # Test DB connectivity before proceeding
  test_db_connection || log_fatal "cannot connect to PostgreSQL — check DB_HOST, DB_PORT, DB_ADMIN_USER"

  ensure_db_role

  # Install Odoo and set up Python environment
  case "$mode" in
    source)
      setup_python_env
      ODOO_BIN=""
      ;;
    deb)
      install_deb_package
      ;;
    exe)
      install_windows_exe
      ;;
  esac

  write_odoo_conf
  write_runtime_env
  restore_database

  # Clear rollback stack on successful completion
  rollback_clear
}

# Bootstrap + start Odoo detached (background bootstrap mode).
bootstrap_detached() {
  set_bootstrap_exit_trap
  prepare_environment

  if [[ "$START_AFTER_RESTORE" == "1" ]]; then
    log_info "starting Odoo on port $ODOO_HTTP_PORT"
    start_odoo_detached -d "$DB_NAME" --http-port="$ODOO_HTTP_PORT"
    healthcheck_odoo
  else
    log_info "bootstrap complete; start manually with: $ROOT/setup_odoo.sh run -d $DB_NAME"
  fi
}

# Bootstrap + run Odoo in foreground (exec mode).
foreground_bootstrap() {
  set_bootstrap_exit_trap
  prepare_environment

  if [[ "$START_AFTER_RESTORE" == "1" ]]; then
    log_info "starting Odoo in foreground on port $ODOO_HTTP_PORT"
    run_odoo -d "$DB_NAME" --http-port="$ODOO_HTTP_PORT"
  else
    log_info "bootstrap complete; run later with: $ROOT/setup_odoo.sh run -d $DB_NAME"
  fi
}

# ============================================================================
# Command dispatcher
# ============================================================================
case "$CMD" in
  start)
    start_background
    ;;
  bootstrap)
    bootstrap_detached "$@"
    ;;
  foreground)
    foreground_bootstrap "$@"
    ;;
  run)
    run_odoo "$@"
    ;;
  status)
    status_background
    ;;
  logs)
    ensure_dirs
    tail -f "$BOOTSTRAP_LOG"
    ;;
  stop)
    stop_background
    ;;
  --version|-V)
    printf 'setup_odoo.sh v%s\n' "$SETUP_ODOO_VERSION"
    ;;
  help|-h|--help)
    usage
    ;;
  *)
    usage >&2
    exit 1
    ;;
esac
