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

# Auto-chmod: ensure this script and helpers are executable
[[ -x "${BASH_SOURCE[0]}" ]] || chmod +x "${BASH_SOURCE[0]}" 2>/dev/null || true

# ============================================================================
# Root directory and CLI argument parsing
# ============================================================================
ROOT="${ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}"
CMD="${1:-start}"
if [[ $# -gt 0 ]]; then
  shift
fi
ENV_FILE="${ENV_FILE:-$ROOT/.env}"

trim_env_field() {
  local value="$1"
  value="${value#"${value%%[![:space:]]*}"}"
  value="${value%"${value##*[![:space:]]}"}"
  printf '%s' "$value"
}

strip_env_inline_comment() {
  local value="$1"
  local result="" char prev_char="" i
  local in_single=0
  local in_double=0
  local escaped=0

  for (( i=0; i<${#value}; i++ )); do
    char="${value:i:1}"

    if (( escaped )); then
      result+="$char"
      prev_char="$char"
      escaped=0
      continue
    fi

    if (( in_double )) && [[ "$char" == "\\" ]]; then
      result+="$char"
      prev_char="$char"
      escaped=1
      continue
    fi

    if (( !in_double )) && [[ "$char" == "'" ]]; then
      (( in_single = 1 - in_single ))
      result+="$char"
      prev_char="$char"
      continue
    fi

    if (( !in_single )) && [[ "$char" == '"' ]]; then
      (( in_double = 1 - in_double ))
      result+="$char"
      prev_char="$char"
      continue
    fi

    if (( !in_single && !in_double )) && [[ "$char" == "#" ]]; then
      if [[ -z "$result" || "$prev_char" =~ [[:space:]] ]]; then
        break
      fi
    fi

    result+="$char"
    prev_char="$char"
  done

  trim_env_field "$result"
}

load_env_file() {
  local env_file="$1"
  local line key value quote_char

  [[ -f "$env_file" ]] || return 0

  while IFS= read -r line || [[ -n "$line" ]]; do
    line="$(trim_env_field "$line")"
    [[ -z "$line" || "$line" == \#* ]] && continue

    if [[ "$line" == export[[:space:]]* ]]; then
      line="$(trim_env_field "${line#export}")"
    fi

    [[ "$line" == *=* ]] || continue

    key="$(trim_env_field "${line%%=*}")"
    value="$(trim_env_field "${line#*=}")"
    value="$(strip_env_inline_comment "$value")"

    [[ "$key" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || continue

    if [[ -z "${!key+x}" ]]; then
      if (( ${#value} >= 2 )); then
        quote_char="${value:0:1}"
        if [[ "$quote_char" == "'" || "$quote_char" == '"' ]] && [[ "${value: -1}" == "$quote_char" ]]; then
          value="${value:1:${#value}-2}"
        fi
      fi
      printf -v "$key" '%s' "$value"
      export "$key"
    fi
  done <"$env_file"
}

load_env_file "$ENV_FILE"

# ============================================================================
# Load modular library (or show helpful error)
# ============================================================================
LIB_DIR="$ROOT/lib"
if [[ -d "$LIB_DIR" && -f "$LIB_DIR/_bootstrap.sh" ]]; then
  # Preserve original env var values before anything else overrides them
  ORIGINAL_DB_PASSWORD="${DB_PASSWORD-__unset__}"
  ORIGINAL_ODOO_ADMIN_PASSWD="${ODOO_ADMIN_PASSWD-__unset__}"
  ORIGINAL_ODOO_WEB_LOGIN="${ODOO_WEB_LOGIN-__unset__}"
  ORIGINAL_ODOO_WEB_LOGIN_PASSWORD="${ODOO_WEB_LOGIN_PASSWORD-__unset__}"
  ORIGINAL_ODOO_HTTP_INTERFACE="${ODOO_HTTP_INTERFACE-__unset__}"

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
  ODOO_WEB_LOGIN="${ODOO_WEB_LOGIN:-}"
  ODOO_WEB_LOGIN_PASSWORD="${ODOO_WEB_LOGIN_PASSWORD:-}"
  ODOO_WEB_LOGIN_RESET="${ODOO_WEB_LOGIN_RESET:-1}"
  ODOO_HTTP_PORT="${ODOO_HTTP_PORT:-8069}"
  ODOO_GEVENT_PORT="${ODOO_GEVENT_PORT:-8072}"
  ODOO_HTTP_INTERFACE="${ODOO_HTTP_INTERFACE:-127.0.0.1}"
  ODOO_EXPOSE_HTTP="${ODOO_EXPOSE_HTTP:-0}"
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
  ODOO_RUNTIME_AUTO_REPAIR="${ODOO_RUNTIME_AUTO_REPAIR:-1}"
  ODOO_DEPENDENCY_REPAIR_RETRIES="${ODOO_DEPENDENCY_REPAIR_RETRIES:-3}"
  ODOO_DEPENDENCY_REPAIR_RETRY_DELAY="${ODOO_DEPENDENCY_REPAIR_RETRY_DELAY:-5}"
  ODOO_BIN="${ODOO_BIN:-}"
  OS_FAMILY="${OS_FAMILY:-}"
  LINUX_DISTRO="${LINUX_DISTRO:-}"
  MIN_FREE_GB="${MIN_FREE_GB:-20}"
  HEALTHCHECK_TIMEOUT="${HEALTHCHECK_TIMEOUT:-120}"
  FETCH_START_DOWNLOAD_RETRIES="${FETCH_START_DOWNLOAD_RETRIES:-3}"
  FETCH_START_DOWNLOAD_RETRY_DELAY="${FETCH_START_DOWNLOAD_RETRY_DELAY:-10}"
  FETCH_START_SKIP_DOWNLOAD="${FETCH_START_SKIP_DOWNLOAD:-0}"
  FETCH_START_MIN_ARTIFACT_SIZE_KB="${FETCH_START_MIN_ARTIFACT_SIZE_KB:-100}"
  FETCH_START_VALIDATE_URL="${FETCH_START_VALIDATE_URL:-1}"
  FETCH_START_CHECK_PORT="${FETCH_START_CHECK_PORT:-1}"
  FETCH_START_REQUIRE_ODOO="${FETCH_START_REQUIRE_ODOO:-1}"
  FETCH_START_REQUIRE_BACKUP="${FETCH_START_REQUIRE_BACKUP:-1}"
  FETCH_START_REQUIRE_ADDONS="${FETCH_START_REQUIRE_ADDONS:-1}"
  FETCH_START_MIN_RAM_GB="${FETCH_START_MIN_RAM_GB:-2}"
  FETCH_START_AUTO_INSTALL_MODULES="${FETCH_START_AUTO_INSTALL_MODULES:-1}"
  FETCH_START_CLEAR_CACHE="${FETCH_START_CLEAR_CACHE:-0}"
  FETCH_START_FORCE_REDOWNLOAD="${FETCH_START_FORCE_REDOWNLOAD:-0}"

  if [[ "$ODOO_EXPOSE_HTTP" == "1" && "$ORIGINAL_ODOO_HTTP_INTERFACE" == "__unset__" ]]; then
    ODOO_HTTP_INTERFACE="0.0.0.0"
  fi

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
  ./setup_odoo.sh fetch-start <google_drive_folder_url>
  ./setup_odoo.sh bootstrap
  ./setup_odoo.sh foreground
  ./setup_odoo.sh run [-d <db_name>]
  ./setup_odoo.sh status
  ./setup_odoo.sh logs
  ./setup_odoo.sh stop
  ./setup_odoo.sh uninstall [--yes]
  ./setup_odoo.sh --version
  ./setup_odoo.sh help

Commands:
  start       Run bootstrap in background, then start Odoo detached.
  fetch-start Download artifacts from a Google Drive folder, then bootstrap and start Odoo.
  bootstrap   Run bootstrap once in the current shell and start Odoo detached.
  foreground  Run bootstrap once in the current shell and then exec Odoo attached.
  run         Run Odoo immediately using the last generated runtime files.
  status      Show bootstrap/Odoo PID and port status.
  logs        Follow bootstrap log.
  stop        Stop only the Odoo/bootstrap PIDs created by this script.
  uninstall   Remove everything: stop services, drop database, remove files.
              Use --yes to skip confirmation prompt.
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
  ODOO_RUNTIME_AUTO_REPAIR=0|1
  ODOO_DEPENDENCY_REPAIR_RETRIES=3
  ODOO_DEPENDENCY_REPAIR_RETRY_DELAY=5
  CUSTOM_ADDONS_DIR               CUSTOM_ADDONS_ZIP_PATTERNS
  ODOO_TAR_GZ, ODOO_DEB_PACKAGE, ODOO_EXE_PACKAGE
  ODOO_HTTP_PORT, ODOO_GEVENT_PORT, ODOO_HTTP_INTERFACE
  ODOO_EXPOSE_HTTP=0|1
  ODOO_ADMIN_PASSWD               ODOO_WEB_LOGIN
  ODOO_WEB_LOGIN_PASSWORD         ODOO_WEB_LOGIN_RESET=0|1
  ODOO_PACKAGE_SHA256
  ODOO_PROXY_MODE=0|1             ODOO_LIST_DB=0|1
  ODOO_WORKERS=<n>|auto
  START_AFTER_RESTORE=0|1
  MIN_FREE_GB                     HEALTHCHECK_TIMEOUT
  FETCH_START_DOWNLOAD_RETRIES=3  FETCH_START_DOWNLOAD_RETRY_DELAY=10
  FETCH_START_SKIP_DOWNLOAD=0|1   FETCH_START_MIN_ARTIFACT_SIZE_KB=100
  FETCH_START_VALIDATE_URL=0|1    FETCH_START_CHECK_PORT=0|1
  FETCH_START_REQUIRE_ODOO=0|1    FETCH_START_REQUIRE_BACKUP=0|1
  FETCH_START_REQUIRE_ADDONS=0|1  FETCH_START_MIN_RAM_GB=2
  FETCH_START_AUTO_INSTALL_MODULES=0|1  FETCH_START_CLEAR_CACHE=0|1
  FETCH_START_FORCE_REDOWNLOAD=0|1
  GDOWN_TIMEOUT=0
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
# Pre-flight System Check
# ============================================================================

# Comprehensive pre-flight check for fetch-start: OS, RAM, disk, ports, toolchain.
# Dies immediately with a specific error message if any check fails.
preflight_system_check() {
  local errors=0
  local mem_gb

  log_info "═══ PRE-FLIGHT SYSTEM CHECK ═══"

  # 1. OS validation
  log_info "  [1/7] OS detection..."
  if [[ "$OS_FAMILY" != "linux" ]]; then
    log_error "  [FAIL] fetch-start is designed for Linux (detected: $OS_FAMILY). Use setup_odoo.ps1 on Windows or follow manual install for macOS."
    (( errors++ ))
  else
    log_info "  [OK]   OS: $OS_FAMILY / $LINUX_DISTRO"
  fi

  # 2. RAM check
  log_info "  [2/7] RAM check..."
  mem_gb="$(detect_memory_gb)"
  if [[ "$mem_gb" =~ ^[0-9]+$ ]] && (( mem_gb > 0 )); then
    if (( mem_gb < FETCH_START_MIN_RAM_GB )); then
      log_error "  [FAIL] Insufficient RAM: ${mem_gb}GB detected, minimum ${FETCH_START_MIN_RAM_GB}GB required. Odoo will be unstable."
      (( errors++ ))
    else
      log_info "  [OK]   RAM: ${mem_gb}GB (min: ${FETCH_START_MIN_RAM_GB}GB)"
    fi
  else
    log_warn "  [WARN] Could not detect RAM — proceeding anyway"
  fi

  # 3. Disk space check
  log_info "  [3/7] Disk space check..."
  local available_gb
  if command -v df >/dev/null 2>&1; then
    available_gb="$(df -BG "$ROOT" 2>/dev/null | awk 'NR==2 {sub(/G$/,"",$4); print $4}' || echo "0")"
    if [[ "$available_gb" =~ ^[0-9]+$ ]] && (( available_gb < MIN_FREE_GB )); then
      log_error "  [FAIL] Insufficient disk space: ${available_gb}GB free, minimum ${MIN_FREE_GB}GB required"
      (( errors++ ))
    else
      log_info "  [OK]   Disk: ${available_gb}GB free (min: ${MIN_FREE_GB}GB)"
    fi
  fi

  # 4. Port availability check (8069 and 5432)
  log_info "  [4/7] Port availability check..."
  if [[ "$FETCH_START_CHECK_PORT" != "1" ]]; then
    log_info "  [INFO] HTTP port availability check skipped (FETCH_START_CHECK_PORT=$FETCH_START_CHECK_PORT)"
  elif has_existing_fetch_start_deployment; then
    log_info "  [INFO] Existing deployment detected — skipping HTTP port availability check for idempotent rerun"
  elif ! _check_port_available "$ODOO_HTTP_PORT"; then
    log_error "  [FAIL] Port $ODOO_HTTP_PORT is already in use — stop the conflicting service or set ODOO_HTTP_PORT to another value"
    (( errors++ ))
  else
    log_info "  [OK]   Port $ODOO_HTTP_PORT (HTTP) is available"
  fi
  if ! _check_port_available 5432; then
    log_warn "  [WARN] Port 5432 (PostgreSQL) is in use — PostgreSQL may already be installed"
  else
    log_info "  [OK]   Port 5432 (PostgreSQL) is available"
  fi

  # 5. Dependency toolchain check
  log_info "  [5/7] Dependency toolchain check..."
  local missing_tools=()
  for cmd in git curl python3 pip3; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
      missing_tools+=("$cmd")
    fi
  done

  # Check gdown (can be auto-installed, so just warn)
  if ! command -v gdown >/dev/null 2>&1; then
    log_info "  [INFO] gdown not found globally — will be auto-installed into venv"
  fi

  if (( ${#missing_tools[@]} > 0 )); then
    log_error "  [FAIL] Missing required tools: ${missing_tools[*]}"
    (( errors++ ))
  else
    log_info "  [OK]   Toolchain: git, curl, python3, pip3 all available"
  fi

  # 6. PostgreSQL client check
  log_info "  [6/7] PostgreSQL client check..."
  if ! command -v psql >/dev/null 2>&1; then
    log_warn "  [WARN] psql not found — will be installed as part of system packages"
  else
    log_info "  [OK]   psql is available"
  fi

  # 7. Network connectivity check
  log_info "  [7/7] Network connectivity check..."
  if command -v curl >/dev/null 2>&1; then
    if curl -fsS --max-time 10 --connect-timeout 5 "https://drive.google.com" >/dev/null 2>&1; then
      log_info "  [OK]   Google Drive is reachable"
    else
      log_warn "  [WARN] Cannot reach drive.google.com — check your internet connection"
    fi
  fi

  if (( errors > 0 )); then
    log_error "═══ PRE-FLIGHT FAILED: $errors error(s) found — fix the issues above and retry ═══"
    return 1
  fi

  log_info "═══ PRE-FLIGHT PASSED: All checks OK ═══"
  return 0
}

# Validate that a URL is a Google Drive folder URL.
# Supports both direct folder URLs and URLs with usp=sharing parameter.
# Arguments: $1=url
# Returns 0 if valid, 1 otherwise.
_validate_gdrive_url() {
  local url="$1"
  # Match: https://drive.google.com/drive/folders/<ID>
  # Also match with query parameters like ?usp=sharing
  [[ "$url" =~ ^https://drive\.google\.com/drive/folders/[A-Za-z0-9_-]+ ]]
}

# Check that the Odoo HTTP port is not already in use.
# Returns 0 if port is free, 1 if occupied.
_check_port_available() {
  local port="$1"
  if command -v lsof >/dev/null 2>&1; then
    lsof -nP -iTCP:"$port" -sTCP:LISTEN >/dev/null 2>&1 && return 1
  elif command -v ss >/dev/null 2>&1; then
    ss -tlnp 2>/dev/null | grep -q ":${port} " && return 1
  elif command -v netstat >/dev/null 2>&1; then
    netstat -tlnp 2>/dev/null | grep -q ":${port} " && return 1
  fi
  return 0
}

# Search for user-provided artifacts while excluding generated workspace paths.
# Arguments: $1=maxdepth, remaining args=additional find predicates
_find_fetch_start_files() {
  local maxdepth="$1"
  shift

  find "$ROOT" -maxdepth "$maxdepth" \
    \( -path "$RESTORE_WORKDIR" -o -path "$RESTORE_WORKDIR/*" \
       -o -path "$ARTIFACTS_DIR" -o -path "$ARTIFACTS_DIR/*" \
       -o -path "$ROOT/.logs" -o -path "$ROOT/.logs/*" \
       -o -path "$ROOT/.run" -o -path "$ROOT/.run/*" \
       -o -path "$ROOT/.rollback" -o -path "$ROOT/.rollback/*" \
       -o -path "$ROOT/.local" -o -path "$ROOT/.local/*" \
       -o -path "$ROOT/.venv" -o -path "$ROOT/.venv/*" \
       -o -path "$ROOT/.downloads" -o -path "$ROOT/.downloads/*" \
       -o -path "$ROOT/.git" -o -path "$ROOT/.git/*" \) -prune -o \
    "$@" -print
}

_artifact_size_kb() {
  local file="$1"
  local size_bytes=0

  if [[ -f "$file" ]]; then
    size_bytes="$(wc -c < "$file" 2>/dev/null | tr -d '[:space:]' || echo 0)"
  fi
  [[ "$size_bytes" =~ ^[0-9]+$ ]] || size_bytes=0
  printf '%s\n' "$(( size_bytes / 1024 ))"
}

count_fetch_start_artifacts() {
  find "$ROOT" -maxdepth 2 -type f \
    \( -name 'odoo*.tar.gz' -o -name 'odoo*.deb' -o -name 'dump.sql' -o -name '*.dump' -o -name '*.backup' \) \
    ! -path "$ARTIFACTS_DIR/*" \
    ! -path "$ROOT/.venv*" \
    ! -path "$ROOT/.git/*" \
    ! -path "$ROOT/.downloads/*" 2>/dev/null | wc -l | tr -d ' '
}

has_existing_fetch_start_deployment() {
  local existing_count

  [[ "$FETCH_START_FORCE_REDOWNLOAD" != "1" ]] || return 1
  [[ -f "$ROOT/odoo.conf" && -f "$SECRETS_ENV_FILE" ]] || return 1

  existing_count="$(count_fetch_start_artifacts)"
  [[ "$existing_count" =~ ^[0-9]+$ ]] || return 1
  (( existing_count >= 3 ))
}

_first_zip_matching_entries() {
  local maxdepth="$1"
  local entry_pattern="$2"
  local archive

  while IFS= read -r archive; do
    if zip_list_entries "$archive" 2>/dev/null | grep -Eq "$entry_pattern"; then
      printf '%s\n' "$archive"
      return 0
    fi
  done < <(_find_fetch_start_files "$maxdepth" -type f -name '*.zip' | sort)

  return 1
}

# Validate downloaded artifacts: check that expected files exist, are not empty,
# and have the correct file extensions. Verifies manifest validity for addons.
_validate_downloaded_artifacts() {
  local min_kb="$FETCH_START_MIN_ARTIFACT_SIZE_KB"
  local found_odoo=0 found_backup=0 found_addons=0 file_size_kb
  local odoo_artifact backup_file backup_zip addons_manifest addons_zip
  local summary

  log_info "═══ ARTIFACT INTEGRITY CHECK ═══"

  odoo_artifact="$(_find_fetch_start_files 2 -type f \( -name 'odoo*.tar.gz' -o -name 'odoo*.deb' -o -name 'odoo*.exe' \) | sort | head -n 1 || true)"
  if [[ -n "$odoo_artifact" ]]; then
    file_size_kb="$(_artifact_size_kb "$odoo_artifact")"
    if (( file_size_kb < min_kb )); then
      log_fatal "downloaded Odoo package is suspiciously small (${file_size_kb}KB < ${min_kb}KB minimum): $odoo_artifact — download may be corrupted"
    fi
    found_odoo=1
    log_info "  [OK] Odoo package: $odoo_artifact (${file_size_kb}KB)"
  fi

  backup_file="$(_find_fetch_start_files 4 -type f \( -name 'dump.sql' -o -name '*.dump' -o -name '*.backup' -o -name '*.sql' \) | sort | head -n 1 || true)"
  if [[ -n "$backup_file" ]]; then
    file_size_kb="$(_artifact_size_kb "$backup_file")"
    if (( file_size_kb < 1 )); then
      log_fatal "downloaded database backup is empty: $backup_file — download may be corrupted"
    fi
    # Validate SQL dump content has recognizable statements
    if [[ "$backup_file" == *.sql ]]; then
      if ! head -c 4096 "$backup_file" 2>/dev/null | grep -qiE '(CREATE|COPY|SET|BEGIN|SELECT|ALTER|INSERT|DROP)'; then
        log_warn "  [WARN] SQL dump does not contain recognizable SQL in header — may be wrong format"
      else
        log_info "  [OK] SQL dump content verified"
      fi
    fi
    # Validate .dump PostgreSQL custom format magic bytes
    if [[ "$backup_file" == *.dump ]]; then
      local magic_bytes
      magic_bytes="$(head -c 5 "$backup_file" 2>/dev/null || true)"
      if [[ "$magic_bytes" != "PGDMP" ]]; then
        log_warn "  [WARN] Custom dump missing PGDMP magic — may not be a valid PostgreSQL dump"
      fi
    fi
    found_backup=1
    log_info "  [OK] Database backup: $backup_file (${file_size_kb}KB)"
  else
    backup_zip="$(_first_zip_matching_entries 3 '(^|/)dump\.sql$|(^|/).+\.(dump|backup|sql)$' || true)"
    if [[ -n "$backup_zip" ]]; then
      file_size_kb="$(_artifact_size_kb "$backup_zip")"
      if (( file_size_kb < 1 )); then
        log_fatal "downloaded backup archive is empty: $backup_zip — download may be corrupted"
      fi
      found_backup=1
      log_info "  [OK] Database backup archive: $backup_zip (${file_size_kb}KB)"
    fi
  fi

  addons_manifest="$(_find_fetch_start_files 4 -type f -name '__manifest__.py' | sort | head -n 1 || true)"
  if [[ -n "$addons_manifest" ]]; then
    # Validate __manifest__.py is parseable Python with required 'name' key
    if command -v python3 >/dev/null 2>&1; then
      if python3 -c "
import ast, sys
try:
    with open(sys.argv[1]) as f:
        data = ast.literal_eval(f.read())
    if not isinstance(data, dict) or 'name' not in data:
        sys.exit(1)
except Exception:
    sys.exit(1)
" "$addons_manifest" 2>/dev/null; then
        local module_dir
        module_dir="$(basename "$(dirname "$addons_manifest")")"
        log_info "  [OK] Addons manifest valid: $module_dir/__manifest__.py"
      else
        log_error "  [FAIL] __manifest__.py is not valid or missing 'name' key: $addons_manifest"
      fi
    else
      log_info "  [OK] Custom addons directory: $(dirname "$addons_manifest")"
    fi
    found_addons=1
  else
    addons_zip="$(_first_zip_matching_entries 3 '(^|/)__manifest__\.py$' || true)"
    if [[ -n "$addons_zip" ]]; then
      file_size_kb="$(_artifact_size_kb "$addons_zip")"
      if (( file_size_kb < min_kb )); then
        log_fatal "downloaded addons archive is suspiciously small (${file_size_kb}KB < ${min_kb}KB minimum): $addons_zip — download may be corrupted"
      fi
      found_addons=1
      log_info "  [OK] Addons archive: $addons_zip (${file_size_kb}KB)"
    fi
  fi

  if (( found_odoo == 0 && found_backup == 0 && found_addons == 0 )); then
    log_fatal "no usable artifacts found after download — check the Google Drive folder contents and URL"
  fi
  if [[ "$FETCH_START_REQUIRE_ODOO" == "1" && $found_odoo -eq 0 ]]; then
    log_fatal "fetch-start requires an Odoo installer/source artifact, but none was found after download"
  fi
  if [[ "$FETCH_START_REQUIRE_BACKUP" == "1" && $found_backup -eq 0 ]]; then
    log_fatal "fetch-start requires a database backup so restored data is available, but none was found after download"
  fi
  if [[ "$FETCH_START_REQUIRE_ADDONS" == "1" && $found_addons -eq 0 ]]; then
    log_fatal "fetch-start requires custom addons so restored modules are visible, but none was found after download"
  fi

  summary="artifact validation: odoo=$found_odoo, backup=$found_backup, addons=$found_addons"
  log_info "═══ INTEGRITY CHECK PASSED: $summary ═══"
}

# Download artifacts from Google Drive with retry logic and idempotency guard.
# Arguments: $1=url
download_drive_artifacts() {
  local url="${1:-}"
  [[ -n "$url" ]] || log_fatal "google drive folder url is required for fetch-start"
  [[ -f "$ROOT/download_drive_folder.sh" ]] || log_fatal "download_drive_folder.sh not found at $ROOT"

  # URL validation
  if [[ "$FETCH_START_VALIDATE_URL" == "1" ]] && ! _validate_gdrive_url "$url"; then
    log_fatal "invalid Google Drive folder URL: $url — expected format: https://drive.google.com/drive/folders/<ID>"
  fi

  # --- Idempotency guard: detect existing deployment ---
  if [[ "$FETCH_START_FORCE_REDOWNLOAD" != "1" ]]; then
    local existing_count
    existing_count="$(count_fetch_start_artifacts)"
    if [[ "$existing_count" =~ ^[0-9]+$ ]] && (( existing_count >= 3 )); then
      log_info "═══ IDEMPOTENCY GUARD ═══"
      log_info "Found $existing_count artifact(s) from a previous download"
      if has_existing_fetch_start_deployment; then
        log_info "Previous deployment detected (odoo.conf + secrets exist)"
        log_info "  To force re-download: re-run with FETCH_START_FORCE_REDOWNLOAD=1"
        log_info "  To clear cache and start fresh: re-run with FETCH_START_CLEAR_CACHE=1"
        if [[ "$FETCH_START_SKIP_DOWNLOAD" == "1" ]]; then
          log_info "  FETCH_START_SKIP_DOWNLOAD=1 — skipping download, validating existing artifacts"
          _validate_downloaded_artifacts
          return 0
        fi
        # Even without explicit skip, if we have a full deployment, ask before re-downloading
        log_warn "Existing deployment detected — to re-download from scratch, set FETCH_START_FORCE_REDOWNLOAD=1"
        log_info "Validating existing artifacts..."
        _validate_downloaded_artifacts
        return 0
      fi
      log_info "Partial artifacts found — proceeding with download to update"
    fi
  fi

  # --- Clear cache if requested ---
  if [[ "$FETCH_START_CLEAR_CACHE" == "1" ]]; then
    log_info "FETCH_START_CLEAR_CACHE=1 — clearing cached downloads and extracted artifacts"
    rm -rf "$ROOT/.downloads" 2>/dev/null || true
    rm -rf "$ROOT/.artifacts" 2>/dev/null || true
    # Remove previously downloaded root-level artifacts (not scripts/configs)
    find "$ROOT" -maxdepth 2 -type f \( -name 'odoo*.tar.gz' -o -name 'dump.sql' -o -name '*.dump' -o -name '*.backup' -o -name '*addons*.zip' \) ! -name '*.sh' ! -name '*.conf' ! -name '*.env' -delete 2>/dev/null || true
    log_info "Cache cleared"
  fi

  # --- Download with retry ---
  local retries="$FETCH_START_DOWNLOAD_RETRIES"
  local retry_delay="$FETCH_START_DOWNLOAD_RETRY_DELAY"
  local attempt=1
  local last_error=""

  while (( attempt <= retries )); do
    log_info "downloading Odoo artifacts from Google Drive (attempt $attempt/$retries)"
    local download_exit_code=0
    if bash "$ROOT/download_drive_folder.sh" run "$url"; then
      log_info "download completed successfully on attempt $attempt"
      _validate_downloaded_artifacts
      return 0
    else
      download_exit_code=$?
    fi

    last_error="exit code $download_exit_code"
    # Detect common gdown errors for better messages
    if [[ -f "$ROOT/.logs/drive-folder-download.log" ]]; then
      local log_tail
      log_tail="$(tail -c 500 "$ROOT/.logs/drive-folder-download.log" 2>/dev/null || true)"
      if [[ "$log_tail" == *"quota"* ]] || [[ "$log_tail" == *"rate"* ]]; then
        last_error="Google Drive quota/rate limit exceeded"
      elif [[ "$log_tail" == *"cannot find"* ]] || [[ "$log_tail" == *"not found"* ]]; then
        last_error="File/folder not found on Google Drive"
      elif [[ "$log_tail" == *"permission"* ]] || [[ "$log_tail" == *"access"* ]]; then
        last_error="Access denied — check folder sharing permissions"
      fi
    fi

    if (( attempt == retries )); then
      log_fatal "download failed after $retries attempts ($last_error) — check your internet connection, Google Drive URL, and folder sharing permissions"
    fi

    log_warn "download attempt $attempt/$retries failed ($last_error), retrying in ${retry_delay}s..."
    sleep "$retry_delay"
    (( attempt++ ))
  done
}

# Print a production-ready success banner with all credentials and next steps.
print_access_summary() {
  local port="${ODOO_HTTP_PORT:-8069}"
  local admin_pw="${ODOO_ADMIN_PASSWD:-}"
  local web_login="${ODOO_WEB_LOGIN:-}"
  local web_pw="${ODOO_WEB_LOGIN_PASSWORD:-}"
  local ip_list ip_addr
  local addons_count=0
  local db_table_count=0
  local db_user_count=0
  local db_module_count=0

  # Count custom addons
  if [[ -n "${CUSTOM_ADDONS_DIR:-}" && -d "${CUSTOM_ADDONS_DIR:-}" ]]; then
    addons_count="$(find "$CUSTOM_ADDONS_DIR" -maxdepth 2 -name '__manifest__.py' 2>/dev/null | wc -l | tr -d ' ')"
  fi

  # Query database for record counts (post-deployment verification)
  if command -v psql >/dev/null 2>&1; then
    db_table_count="$(PGPASSWORD="$DB_PASSWORD" psql -h "$DB_HOST" -p "$DB_PORT" -U "$DB_USER" -d "$DB_NAME" -Atqc "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema='public';" 2>/dev/null | tr -d ' ' || echo "0")"
    db_user_count="$(PGPASSWORD="$DB_PASSWORD" psql -h "$DB_HOST" -p "$DB_PORT" -U "$DB_USER" -d "$DB_NAME" -Atqc "SELECT COUNT(*) FROM res_users WHERE active IS TRUE;" 2>/dev/null | tr -d ' ' || echo "0")"
    db_module_count="$(PGPASSWORD="$DB_PASSWORD" psql -h "$DB_HOST" -p "$DB_PORT" -U "$DB_USER" -d "$DB_NAME" -Atqc "SELECT COUNT(*) FROM ir_module_module WHERE state='installed';" 2>/dev/null | tr -d ' ' || echo "0")"
  fi

  # Collect all non-loopback IPv4 addresses
  ip_list=()
  if command -v hostname >/dev/null 2>&1; then
    while IFS= read -r ip_addr; do
      [[ -n "$ip_addr" ]] && ip_list+=("$ip_addr")
    done < <(hostname -I 2>/dev/null | tr ' ' '\n' | grep -E '^[0-9]+\.' || true)
  fi
  if command -v ip >/dev/null 2>&1 && (( ${#ip_list[@]} == 0 )); then
    while IFS= read -r ip_addr; do
      [[ -n "$ip_addr" ]] && ip_list+=("$ip_addr")
    done < <(ip -4 -o addr show scope global 2>/dev/null | awk '{print $4}' | cut -d/ -f1 || true)
  fi
  if command -v ifconfig >/dev/null 2>&1 && (( ${#ip_list[@]} == 0 )); then
    while IFS= read -r ip_addr; do
      [[ -n "$ip_addr" ]] && ip_list+=("$ip_addr")
    done < <(ifconfig 2>/dev/null | grep 'inet ' | awk '{print $2}' | grep -v '127\.' || true)
  fi

  printf '\n' >&2
  log_info "╔══════════════════════════════════════════════════════════════════╗"
  log_info "║        ODOO DEPLOYMENT COMPLETE — PRODUCTION READY             ║"
  log_info "╚══════════════════════════════════════════════════════════════════╝"
  log_info ""
  log_info "  Database        : $DB_NAME"
  log_info "  DB Tables       : ${db_table_count} tables"
  log_info "  Active Users    : ${db_user_count}"
  log_info "  Installed Modules: ${db_module_count}"
  log_info "  Custom Addons   : ${addons_count} module(s)"
  log_info "  Port            : $port"
  log_info "  Interface       : $ODOO_HTTP_INTERFACE"

  if [[ -n "$admin_pw" ]]; then
    log_info ""
    log_info "  ┌──────────────────────────────────────────────────────────────┐"
    log_info "  │  MASTER PASSWORD (admin_passwd):                             │"
    log_info "  │  $admin_pw"
    log_info "  │  (tersimpan di: $SECRETS_ENV_FILE)"
    log_info "  └──────────────────────────────────────────────────────────────┘"
  fi

  if [[ -n "$web_login" || -n "$web_pw" ]]; then
    log_info ""
    log_info "  ┌──────────────────────────────────────────────────────────────┐"
    log_info "  │  LOGIN ODOO SIAP PAKAI:                                      │"
    if [[ -n "$web_login" ]]; then
      log_info "  │  Username : $web_login"
    else
      log_info "  │  Username : (cek $SECRETS_ENV_FILE)"
    fi
    if [[ -n "$web_pw" ]]; then
      log_info "  │  Password : $web_pw"
    else
      log_info "  │  Password : (mengikuti password user hasil restore)"
    fi
    log_info "  │  (tersimpan di: $SECRETS_ENV_FILE)"
    log_info "  └──────────────────────────────────────────────────────────────┘"
  fi

  log_info ""
  log_info "  ┌──────────────────────────────────────────────────────────────┐"
  log_info "  │  LANGKAH PERTAMA:                                             │"
  log_info "  │  1. Buka URL di bawah di browser                               │"
  log_info "  │  2. Login dengan kredensial di atas                            │"
  log_info "  │  3. Modul custom sudah terinstall — langsung pakai!           │"
  log_info "  │  4. Data sample sudah tersedia dari backup                     │"
  log_info "  └──────────────────────────────────────────────────────────────┘"

  log_info ""
  log_info "  URL Akses:"
  if (( ${#ip_list[@]} > 0 )); then
    for ip_addr in "${ip_list[@]}"; do
      log_info "    http://${ip_addr}:${port}/web/login"
    done
  else
    log_info "    http://localhost:${port}/web/login"
  fi

  log_info ""
  if command -v systemctl >/dev/null 2>&1 && systemctl is-active odoo-cs >/dev/null 2>&1; then
    log_info "  Systemd         : odoo-cs.service ACTIVE (auto-start saat reboot)"
  fi

  log_info ""
  log_info "  Perintah berguna:"
  log_info "    Stop Odoo      : ./setup_odoo.sh stop"
  log_info "    Lihat log      : tail -f $LOG_FILE"
  log_info "    Status         : ./setup_odoo.sh status"
  log_info "    Lihat secret   : cat $SECRETS_ENV_FILE"
  log_info "    Re-download    : FETCH_START_FORCE_REDOWNLOAD=1 ./setup_odoo.sh fetch-start '<URL>'"
  log_info ""
  log_info "════════════════════════════════════════════════════════════════════"
}

# Install basic system prerequisites for fetch-start on a fresh OS.
# Ensures python3, curl, unzip, rsync are available.
ensure_system_prerequisites() {
  if [[ "$OS_FAMILY" != "linux" ]]; then
    return 0
  fi

  local need_install=0
  local pkgs_to_install=()

  for cmd_pkg in "python3:python3" "curl:curl" "unzip:unzip" "rsync:rsync" "pip3:python3-pip" "lsof:lsof"; do
    local cmd="${cmd_pkg%%:*}"
    local pkg="${cmd_pkg##*:}"
    if ! command -v "$cmd" >/dev/null 2>&1; then
      pkgs_to_install+=("$pkg")
      need_install=1
    fi
  done

  if (( need_install )); then
    if [[ "$LINUX_DISTRO" == "ubuntu" || "$LINUX_DISTRO" == "debian" ]]; then
      log_info "Installing prerequisites: ${pkgs_to_install[*]}"
      run_privileged apt-get update -qq
      run_privileged env DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "${pkgs_to_install[@]}"
    else
      log_warn "Some prerequisites may be missing (${pkgs_to_install[*]}) — install them manually if the script fails"
    fi
  fi

  log_info "System prerequisites OK"
}

# Post-deployment validation: verify database connectivity, table counts,
# module detection, and HTTP healthcheck after Odoo is fully started.
_post_deployment_validation() {
  local errors=0

  # 1. Verify database is reachable and has core tables
  log_info "  [1/4] Verifying database connectivity..."
  if command -v psql >/dev/null 2>&1; then
    local db_result
    db_result="$(PGPASSWORD="$DB_PASSWORD" psql -h "$DB_HOST" -p "$DB_PORT" -U "$DB_USER" -d "$DB_NAME" -Atqc "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema='public';" 2>/dev/null | tr -d ' ' || echo "")"
    if [[ "$db_result" =~ ^[0-9]+$ ]] && (( db_result > 0 )); then
      log_info "  [OK]   Database reachable: $DB_NAME ($db_result tables)"
    else
      log_error "  [FAIL] Database $DB_NAME is not reachable or has 0 tables"
      (( errors++ ))
    fi

    # Verify minimum core tables
    local core_tables_count=0
    local core_table
    for core_table in ir_module_module res_users ir_config_parameter; do
      local exists
      exists="$(PGPASSWORD="$DB_PASSWORD" psql -h "$DB_HOST" -p "$DB_PORT" -U "$DB_USER" -d "$DB_NAME" -Atqc "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema='public' AND table_name='$core_table';" 2>/dev/null | tr -d ' ')"
      if [[ "$exists" == "1" ]]; then
        (( core_tables_count++ ))
      fi
    done
    if (( core_tables_count >= 3 )); then
      log_info "  [OK]   Core Odoo tables verified ($core_tables_count/3)"
    else
      log_error "  [FAIL] Missing core Odoo tables (only $core_tables_count/3 found)"
      (( errors++ ))
    fi
  else
    log_warn "  [WARN] psql not available — skipping database verification"
  fi

  # 2. Verify module detection
  log_info "  [2/4] Verifying module detection..."
  if command -v psql >/dev/null 2>&1; then
    local installed_modules custom_installed=0
    installed_modules="$(PGPASSWORD="$DB_PASSWORD" psql -h "$DB_HOST" -p "$DB_PORT" -U "$DB_USER" -d "$DB_NAME" -Atqc "SELECT COUNT(*) FROM ir_module_module WHERE state='installed';" 2>/dev/null | tr -d ' ' || echo "0")"
    custom_installed="$(PGPASSWORD="$DB_PASSWORD" psql -h "$DB_HOST" -p "$DB_PORT" -U "$DB_USER" -d "$DB_NAME" -Atqc "SELECT COUNT(*) FROM ir_module_module WHERE state='installed' AND name NOT IN ('base','web','website','bus','mail','http','base_import','base_setup','web_tour','report','web_settings_dashboard');" 2>/dev/null | tr -d ' ' || echo "0")"
    log_info "  [OK]   Modules: $installed_modules installed ($custom_installed custom)"
  fi

  # 3. Verify custom addons path
  log_info "  [3/4] Verifying custom addons..."
  if [[ -n "${CUSTOM_ADDONS_DIR:-}" && -d "${CUSTOM_ADDONS_DIR:-}" ]]; then
    local manifest_count
    manifest_count="$(find "$CUSTOM_ADDONS_DIR" -maxdepth 2 -name '__manifest__.py' 2>/dev/null | wc -l | tr -d ' ')"
    log_info "  [OK]   Custom addons: $manifest_count module(s) in $CUSTOM_ADDONS_DIR"
  else
    log_warn "  [WARN] Custom addons directory not detected"
  fi

  # 4. HTTP healthcheck (already done in bootstrap_detached, but verify again)
  log_info "  [4/4] Verifying HTTP endpoint..."
  local hc_url
  hc_url="$(healthcheck_url)"
  if command -v curl >/dev/null 2>&1; then
    local http_code
    http_code="$(curl -fsS -o /dev/null -w '%{http_code}' --max-time 10 --connect-timeout 5 "$hc_url" 2>/dev/null || echo "000")"
    if [[ "$http_code" =~ ^(200|302|303|304)$ ]]; then
      log_info "  [OK]   HTTP endpoint responding: $hc_url (HTTP $http_code)"
    else
      log_error "  [FAIL] HTTP endpoint not responding correctly: $hc_url (HTTP $http_code)"
      (( errors++ ))
    fi
  fi

  if (( errors > 0 )); then
    log_warn "Post-deployment validation: $errors issue(s) detected — Odoo may not be fully functional"
  else
    log_info "═══ POST-DEPLOYMENT VALIDATION PASSED ═══"
  fi
}

# ============================================================================
# Uninstall / Clean Removal
# ============================================================================

# Completely uninstall Odoo CS: stop services, drop database, remove all files.
# Arguments: [--yes] to skip interactive confirmation
uninstall_odoo() {
  local auto_yes=0
  if [[ "${1:-}" == "--yes" || "${1:-}" == "-y" ]]; then
    auto_yes=1
  fi

  detect_platform

  log_info "╔══════════════════════════════════════════════════════════════════╗"
  log_info "║              ODOO CS — COMPLETE UNINSTALL                        ║"
  log_info "╚══════════════════════════════════════════════════════════════════╝"
  log_info ""
  log_info "  This will remove:"
  log_info "    • Odoo process and systemd service (odoo-cs)"
  log_info "    • Database: $DB_NAME"
  log_info "    • Database role: $DB_USER"
  log_info "    • Data directory: $DATA_DIR"
  log_info "    • Virtualenv: $VENV_DIR"
  log_info "    • Config, logs, secrets, and runtime files"
  log_info "    • Downloaded artifacts (.downloads/, .artifacts/)"
  log_info "    • Odoo deb package (if installed)"
  log_info ""

  if (( ! auto_yes )); then
    log_warn "  ⚠️  THIS ACTION IS IRREVERSIBLE!"
    printf '\n  Type "UNINSTALL" to confirm: ' >&2
    local confirmation
    read -r confirmation
    if [[ "$confirmation" != "UNINSTALL" ]]; then
      log_info "Uninstall cancelled."
      return 0
    fi
  fi

  log_info ""
  local step=0

  # 1. Stop Odoo processes
  (( step++ ))
  log_info "  [$step] Stopping Odoo processes..."
  local pid
  pid="$(read_pid_file "$ODOO_PID_FILE" 2>/dev/null || true)"
  if [[ -n "$pid" ]] && pid_is_running "$pid" 2>/dev/null; then
    kill "$pid" 2>/dev/null || true
    sleep 2
    kill -9 "$pid" 2>/dev/null || true
    log_info "    Stopped Odoo process: $pid"
  fi
  pid="$(read_pid_file "$BOOTSTRAP_PID_FILE" 2>/dev/null || true)"
  if [[ -n "$pid" ]] && pid_is_running "$pid" 2>/dev/null; then
    kill "$pid" 2>/dev/null || true
    log_info "    Stopped bootstrap process: $pid"
  fi

  # 2. Remove systemd service
  (( step++ ))
  log_info "  [$step] Removing systemd service..."
  if command -v systemctl >/dev/null 2>&1; then
    systemctl stop odoo-cs 2>/dev/null || true
    systemctl disable odoo-cs 2>/dev/null || true
    rm -f /etc/systemd/system/odoo-cs.service
    systemctl daemon-reload 2>/dev/null || true
    log_info "    Removed odoo-cs.service"
  else
    log_info "    systemd not available — skipped"
  fi

  # 3. Drop database
  (( step++ ))
  log_info "  [$step] Dropping database: $DB_NAME..."
  if command -v psql >/dev/null 2>&1; then
    # Load secrets to get DB_PASSWORD
    if [[ -f "$SECRETS_ENV_FILE" ]]; then
      # shellcheck disable=SC1090
      source "$SECRETS_ENV_FILE" 2>/dev/null || true
    fi

    # Validate DB_NAME looks like a real identifier (no SQL injection)
    if ! [[ "$DB_NAME" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]]; then
      log_warn "    DB_NAME='$DB_NAME' contains special chars — using quoted identifier"
    fi
    local db_ident
    db_ident="$(sql_quote_ident "$DB_NAME")"
    local db_lit
    db_lit="$(sql_escape_literal "$DB_NAME")"

    # Terminate active connections first
    if [[ -n "${DB_ADMIN_PASSWORD:-}" ]]; then
      PGPASSWORD="$DB_ADMIN_PASSWORD" psql -h "$DB_HOST" -p "$DB_PORT" -U "$DB_ADMIN_USER" -d postgres -Atqc \
        "SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname = '$db_lit' AND pid <> pg_backend_pid();" 2>/dev/null || true
      PGPASSWORD="$DB_ADMIN_PASSWORD" psql -h "$DB_HOST" -p "$DB_PORT" -U "$DB_ADMIN_USER" -d postgres -Atqc \
        "DROP DATABASE IF EXISTS $db_ident;" 2>/dev/null && log_info "    Dropped database: $DB_NAME" || log_warn "    Could not drop database (may need manual: DROP DATABASE $db_ident;)"
    elif db_host_is_local 2>/dev/null && command -v sudo >/dev/null 2>&1; then
      sudo -u "$DB_ADMIN_USER" psql -d postgres -Atqc \
        "SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname = '$db_lit' AND pid <> pg_backend_pid();" 2>/dev/null || true
      sudo -u "$DB_ADMIN_USER" psql -d postgres -Atqc \
        "DROP DATABASE IF EXISTS $db_ident;" 2>/dev/null && log_info "    Dropped database: $DB_NAME" || log_warn "    Could not drop database"
    else
      log_warn "    Cannot connect as admin — drop database manually: DROP DATABASE $db_ident;"
    fi
  fi

  # 4. Drop database role
  (( step++ ))
  log_info "  [$step] Dropping database role: $DB_USER..."
  if command -v psql >/dev/null 2>&1; then
    local user_ident
    user_ident="$(sql_quote_ident "$DB_USER")"
    if [[ -n "${DB_ADMIN_PASSWORD:-}" ]]; then
      PGPASSWORD="$DB_ADMIN_PASSWORD" psql -h "$DB_HOST" -p "$DB_PORT" -U "$DB_ADMIN_USER" -d postgres -Atqc \
        "DROP ROLE IF EXISTS $user_ident;" 2>/dev/null && log_info "    Dropped role: $DB_USER" || log_warn "    Could not drop role"
    elif db_host_is_local 2>/dev/null && command -v sudo >/dev/null 2>&1; then
      sudo -u "$DB_ADMIN_USER" psql -d postgres -Atqc \
        "DROP ROLE IF EXISTS $user_ident;" 2>/dev/null && log_info "    Dropped role: $DB_USER" || log_warn "    Could not drop role"
    fi
  fi

  # 5. Remove Odoo deb package
  (( step++ ))
  log_info "  [$step] Removing Odoo deb package..."
  if dpkg -l odoo 2>/dev/null | grep -q '^ii'; then
    if command -v apt-get >/dev/null 2>&1; then
      run_privileged apt-get remove -y odoo 2>/dev/null || true
      log_info "    Removed odoo deb package"
    fi
  else
    log_info "    No odoo deb package installed — skipped"
  fi

  # 6. Remove service user (only if we created it)
  (( step++ ))
  local service_user="${ODOO_SERVICE_USER:-odoo}"
  log_info "  [$step] Removing service user: $service_user..."
  if id "$service_user" >/dev/null 2>&1; then
    if command -v userdel >/dev/null 2>&1; then
      userdel "$service_user" 2>/dev/null || true
      log_info "    Removed user: $service_user"
    fi
  else
    log_info "    User $service_user does not exist — skipped"
  fi

  # 7. Remove data directories and generated files
  (( step++ ))
  log_info "  [$step] Removing data and generated files..."
  local items_removed=0
  local dirs_to_remove=(
    "$DATA_DIR"
    "$VENV_DIR"
    "$ROOT/.venv-drive-fetch"
    "$ROOT/.downloads"
    "$ARTIFACTS_DIR"
    "$RESTORE_WORKDIR"
    "$ROOT/.logs"
    "$ROOT/.run"
    "$ROOT/.rollback"
    "$ROOT/.local"
    "$LOCK_DIR"
  )
  for dir in "${dirs_to_remove[@]}"; do
    if [[ -d "$dir" ]]; then
      rm -rf "$dir"
      (( items_removed++ ))
    fi
  done

  local files_to_remove=(
    "$ROOT/odoo.conf"
    "$SECRETS_ENV_FILE"
    "$RUNTIME_ENV_FILE"
    "$ROOT/.odoo.secrets.ps1"
    "$ROOT/.odoo_runtime.ps1"
    "$LOG_FILE"
    "$ODOO_STDOUT_LOG"
    "$ODOO_PID_FILE"
    "$BOOTSTRAP_PID_FILE"
    "$BOOTSTRAP_LOG"
    "$ROOT/.env"
  )
  for file in "${files_to_remove[@]}"; do
    if [[ -f "$file" ]]; then
      rm -f "$file"
      (( items_removed++ ))
    fi
  done

  # Remove downloaded artifacts (tar.gz, deb, exe, zip, sql dumps)
  find "$ROOT" -maxdepth 2 -type f \( \
    -name 'odoo*.tar.gz' -o -name 'odoo*.deb' -o -name 'odoo*.exe' \
    -o -name 'dump.sql' -o -name '*.dump' -o -name '*.backup' \
    -o -name '*.bak' -o -name '*.bak[0-9]' \
  \) ! -name 'setup_odoo.sh' ! -name 'download_drive_folder.sh' -delete 2>/dev/null || true

  # Remove extracted addons zip files
  find "$ROOT" -maxdepth 2 -type f -name '*.zip' \
    ! -name 'setup_odoo.sh' ! -name 'download_drive_folder.sh' -delete 2>/dev/null || true

  # Remove ROOT-level extracted custom addons directories
  # (directories containing __manifest__.py that aren't part of the repo itself)
  local protected_dirs="lib|tests|.git|.github|.agents|.agent|_agents|_agent"
  local addons_dir
  while IFS= read -r addons_dir; do
    local dir_name
    dir_name="$(basename "$addons_dir")"
    # Skip protected repo directories
    if [[ "$dir_name" =~ ^($protected_dirs)$ ]]; then
      continue
    fi
    if find "$addons_dir" -maxdepth 2 -name '__manifest__.py' 2>/dev/null | grep -q .; then
      log_info "    Removing extracted addons dir: $addons_dir"
      rm -rf "$addons_dir"
      (( items_removed++ ))
    fi
  done < <(find "$ROOT" -mindepth 1 -maxdepth 1 -type d 2>/dev/null)

  log_info "    Removed $items_removed directories/files"

  # 8. Close firewall port
  (( step++ ))
  local port="${ODOO_HTTP_PORT:-8069}"
  log_info "  [$step] Closing firewall port $port..."
  if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -qi 'active'; then
    ufw delete allow "$port/tcp" 2>/dev/null || true
    log_info "    Closed port $port via ufw"
  elif command -v firewall-cmd >/dev/null 2>&1; then
    firewall-cmd --permanent --remove-port="$port/tcp" 2>/dev/null || true
    firewall-cmd --reload 2>/dev/null || true
  fi

  # 9. Revert pg_hba.conf changes
  (( step++ ))
  log_info "  [$step] Reverting pg_hba.conf changes..."
  if [[ "$OS_FAMILY" == "linux" ]]; then
    local pg_hba=""
    local pg_version_dir
    for pg_version_dir in /etc/postgresql/*/main; do
      [[ -d "$pg_version_dir" ]] || continue
      pg_hba="$pg_version_dir/pg_hba.conf"
      [[ -f "$pg_hba" ]] && break
      pg_hba=""
    done
    if [[ -n "$pg_hba" ]]; then
      # Remove the lines we added (marked with our comment)
      if grep -q 'Added by setup_odoo.sh' "$pg_hba" 2>/dev/null; then
        run_privileged sed -i '/# Added by setup_odoo.sh/d' "$pg_hba" 2>/dev/null || true
        # Also remove the md5 lines that follow our comment
        run_privileged sed -i '/^host[[:space:]]\+all[[:space:]]\+all[[:space:]]\+127\.0\.0\.1\/32[[:space:]]\+md5$/d' "$pg_hba" 2>/dev/null || true
        run_privileged sed -i '/^host[[:space:]]\+all[[:space:]]\+all[[:space:]]\+::1\/128[[:space:]]\+md5$/d' "$pg_hba" 2>/dev/null || true
        log_info "    Reverted pg_hba.conf entries"
        # Reload PostgreSQL if it's still running
        if systemctl is-active postgresql >/dev/null 2>&1; then
          run_privileged systemctl reload postgresql 2>/dev/null || true
          log_info "    Reloaded PostgreSQL"
        fi
      else
        log_info "    No setup_odoo.sh entries found in pg_hba.conf — skipped"
      fi
    else
      log_info "    pg_hba.conf not found — skipped"
    fi
  fi

  # 10. Uninstall pip packages installed by setup
  (( step++ ))
  log_info "  [$step] Uninstalling pip packages..."
  if command -v python3 >/dev/null 2>&1; then
    python3 -m pip uninstall -y lxml_html_clean 2>/dev/null && \
      log_info "    Removed lxml_html_clean" || true
  fi
  if [[ -x /usr/bin/python3 ]]; then
    /usr/bin/python3 -m pip uninstall -y lxml_html_clean 2>/dev/null || true
  fi
  # Remove python3-lxml-html-clean apt package if installed
  if dpkg -l python3-lxml-html-clean 2>/dev/null | grep -q '^ii'; then
    run_privileged apt-get remove -y python3-lxml-html-clean 2>/dev/null || true
    log_info "    Removed python3-lxml-html-clean apt package"
  fi

  # 11. Remove system packages installed by setup
  (( step++ ))
  log_info "  [$step] Removing system packages installed by setup..."
  if command -v apt-get >/dev/null 2>&1; then
    # Only remove packages that are specific to Odoo and unlikely to be needed by other services
    # We do NOT remove postgresql, python3, curl, git, etc. as they are commonly used
    local odoo_specific_pkgs=(
      wkhtmltopdf
      libldap2-dev
      libsasl2-dev
    )
    local pkgs_to_remove=()
    local pkg
    for pkg in "${odoo_specific_pkgs[@]}"; do
      if dpkg -l "$pkg" 2>/dev/null | grep -q '^ii'; then
        pkgs_to_remove+=("$pkg")
      fi
    done
    if (( ${#pkgs_to_remove[@]} > 0 )); then
      run_privileged apt-get remove -y "${pkgs_to_remove[@]}" 2>/dev/null || true
      run_privileged apt-get autoremove -y 2>/dev/null || true
      log_info "    Removed: ${pkgs_to_remove[*]}"
    else
      log_info "    No Odoo-specific packages to remove"
    fi
  fi

  log_info ""
  log_info "╔══════════════════════════════════════════════════════════════════╗"
  log_info "║              UNINSTALL COMPLETE                                  ║"
  log_info "╚══════════════════════════════════════════════════════════════════╝"
  log_info ""
  log_info "  ✅ Odoo CS telah dihapus sepenuhnya."
  log_info ""
  log_info "  Yang tersisa (sengaja tidak dihapus):"
  log_info "    • Repository odoo-cs ini (setup_odoo.sh, lib/, tests/, dll)"
  log_info "    • PostgreSQL server (shared — bisa dipakai service lain)"
  log_info "    • Core system packages (python3, curl, git, build-essential)"
  log_info ""
  log_info "  Untuk hapus total termasuk repo:"
  log_info "    cd .. && rm -rf odoo-cs"
  log_info ""
  log_info "  Untuk hapus PostgreSQL juga:"
  log_info "    sudo apt-get remove --purge -y postgresql postgresql-contrib"
  log_info "    sudo apt-get autoremove -y"
  log_info ""
}

fetch_start() {
  local url="${1:-}"

  log_info "╔══════════════════════════════════════════════════════════════════╗"
  log_info "║              ODOO FETCH-START — PRODUCTION DEPLOY               ║"
  log_info "╚══════════════════════════════════════════════════════════════════╝"

  # --- Production hardening: auto-expose on all interfaces ---
  if [[ "$ODOO_EXPOSE_HTTP" != "1" && "$ORIGINAL_ODOO_HTTP_INTERFACE" == "__unset__" ]]; then
    log_info "Auto-hardening: exposing Odoo on 0.0.0.0 (all network interfaces)"
    export ODOO_EXPOSE_HTTP="1"
    export ODOO_HTTP_INTERFACE="0.0.0.0"
  fi

  # --- Production hardening: force restore mode to required ---
  if [[ "$RESTORE_MODE" == "auto" ]]; then
    log_info "Auto-hardening: setting RESTORE_MODE=required for fetch-start"
    export RESTORE_MODE="required"
  fi

  # --- Production hardening: extend healthcheck timeout for first boot ---
  if (( HEALTHCHECK_TIMEOUT <= 300 )); then
    log_info "Auto-hardening: extending HEALTHCHECK_TIMEOUT to 600s for first boot"
    export HEALTHCHECK_TIMEOUT=600
  fi

  # --- Production hardening: lower MIN_FREE_GB requirement for fetch-start ---
  if (( MIN_FREE_GB > 5 )); then
    log_info "Auto-hardening: lowering MIN_FREE_GB from ${MIN_FREE_GB} to 5 for fetch-start"
    export MIN_FREE_GB=5
  fi

  # --- Production hardening: security baseline ---
  if [[ "$ODOO_LIST_DB" != "0" ]]; then
    log_info "Auto-hardening: setting ODOO_LIST_DB=False (security: hide database list)"
    export ODOO_LIST_DB="0"
  fi
  if [[ -z "$ODOO_DBFILTER" ]] || [[ "$ODOO_DBFILTER" == "^.*$" ]]; then
    log_info "Auto-hardening: setting ODOO_DBFILTER=^${DB_NAME}$ (security: restrict to target DB)"
    export ODOO_DBFILTER="^${DB_NAME}$"
  fi

  # --- Phase 0: Pre-flight system check (fail fast) ---
  detect_platform
  [[ "$OS_FAMILY" != "windows" ]] || log_fatal "use setup_odoo.ps1 on Windows"

  preflight_system_check || log_fatal "pre-flight system check failed — fix the issues above and retry"

  # --- Pre-flight: auto-chmod helper scripts ---
  chmod +x "$ROOT/download_drive_folder.sh" 2>/dev/null || true

  # --- Pre-flight: install system prerequisites on fresh OS ---
  ensure_system_prerequisites

  # --- Pre-flight: sudo authentication (prevents timeout during downloads) ---
  if command -v sudo >/dev/null 2>&1 && ! is_root_user; then
    log_info "Prompting for sudo password upfront to prevent timeout during long downloads..."
    sudo -v || log_fatal "Sudo authentication failed. Required for PostgreSQL/Odoo installation."
    ( while true; do sudo -n true; sleep 60; kill -0 $$ || exit 0; done 2>/dev/null & )
  fi

  # --- Phase 1: Download artifacts (with idempotency + retry) ---
  log_info "═══ PHASE 1: DOWNLOAD ARTIFACTS ═══"
  download_drive_artifacts "$url"

  # --- Phase 2: Bootstrap and start ---
  log_info "═══ PHASE 2: BOOTSTRAP & START ═══"
  bootstrap_detached

  # --- Phase 3: Post-deployment validation ---
  log_info "═══ PHASE 3: POST-DEPLOYMENT VALIDATION ═══"
  _post_deployment_validation

  # --- Phase 4: Success summary ---
  log_info "═══ PHASE 4: SUCCESS ═══"
  print_access_summary
}

# ============================================================================
# Command dispatcher
# ============================================================================
case "$CMD" in
  start)
    start_background
    ;;
  fetch-start)
    fetch_start "$@"
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
  uninstall)
    uninstall_odoo "$@"
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
