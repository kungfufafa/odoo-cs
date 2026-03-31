#!/usr/bin/env bash
# ============================================================================
# config.sh — Odoo configuration file generation and runtime env management
# ============================================================================
# Generates odoo.conf with auto-tuned worker/memory settings and writes
# a runtime env file for subsequent Odoo start operations.
# ============================================================================

[[ -n "${_CONFIG_SH_LOADED:-}" ]] && return 0
_CONFIG_SH_LOADED=1

# Convert a 0/1 flag to Python-style True/False for odoo.conf.
# Arguments: $1=flag value (0 or 1)
# Output: "True" or "False" on stdout
odoo_bool() {
  if [[ "$1" == "1" ]]; then
    printf 'True\n'
  else
    printf 'False\n'
  fi
}

# Calculate the optimal number of Odoo workers based on CPU and memory.
# Uses the formula: min(cpu*2+1, memory_gb-1), minimum 2, or 0 if <4GB RAM.
# Output: integer worker count on stdout
resolved_odoo_workers() {
  local mem_gb cpu_count cpu_based mem_based workers
  if [[ "$ODOO_WORKERS" != "auto" ]]; then
    printf '%s\n' "$ODOO_WORKERS"
    return 0
  fi

  mem_gb="$(detect_memory_gb)"
  cpu_count="$(detect_cpu_count)"

  if ! [[ "$mem_gb" =~ ^[0-9]+$ ]]; then mem_gb=0; fi
  if ! [[ "$cpu_count" =~ ^[0-9]+$ ]]; then cpu_count=1; fi

  # Disable workers if insufficient memory
  if (( mem_gb < 4 )); then
    printf '0\n'
    return 0
  fi

  cpu_based=$(( cpu_count * 2 + 1 ))
  mem_based=$(( mem_gb - 1 ))
  workers="$cpu_based"
  if (( mem_based < workers )); then
    workers="$mem_based"
  fi
  if (( workers < 2 )); then
    workers=2
  fi
  printf '%s\n' "$workers"
}

# Calculate the soft memory limit for Odoo workers.
# Uses 70% of total RAM, minimum 2GB.
# Output: integer bytes on stdout
resolved_memory_soft() {
  local mem_gb soft
  if [[ "$ODOO_LIMIT_MEMORY_SOFT" != "auto" ]]; then
    printf '%s\n' "$ODOO_LIMIT_MEMORY_SOFT"
    return 0
  fi

  mem_gb="$(detect_memory_gb)"
  if ! [[ "$mem_gb" =~ ^[0-9]+$ ]] || (( mem_gb == 0 )); then
    printf '2147483648\n'
    return 0
  fi

  soft=$(( mem_gb * 1024 * 1024 * 1024 * 70 / 100 ))
  if (( soft < 2147483648 )); then
    soft=2147483648
  fi
  printf '%s\n' "$soft"
}

# Calculate the hard memory limit (120% of soft limit).
# Output: integer bytes on stdout
resolved_memory_hard() {
  local soft
  if [[ "$ODOO_LIMIT_MEMORY_HARD" != "auto" ]]; then
    printf '%s\n' "$ODOO_LIMIT_MEMORY_HARD"
    return 0
  fi

  soft="$(resolved_memory_soft)"
  printf '%s\n' $(( soft * 12 / 10 ))
}

# Generate the odoo.conf configuration file with all resolved settings.
# The generated config includes database, network, worker, and security settings.
write_odoo_conf() {
  local addons_path workers memory_soft memory_hard proxy_mode list_db
  addons_path="$CUSTOM_ADDONS_DIR"
  workers="$(resolved_odoo_workers)"
  memory_soft="$(resolved_memory_soft)"
  memory_hard="$(resolved_memory_hard)"
  proxy_mode="$(odoo_bool "$ODOO_PROXY_MODE")"
  list_db="$(odoo_bool "$ODOO_LIST_DB")"

  # Build addons_path based on installation mode
  if [[ -n "$ODOO_SRC_DIR" ]]; then
    addons_path="$ODOO_SRC_DIR/odoo/addons,$CUSTOM_ADDONS_DIR"
  elif [[ "$OS_FAMILY" == "linux" ]]; then
    addons_path="/usr/lib/python3/dist-packages/odoo/addons,$CUSTOM_ADDONS_DIR"
  fi

  # --- Production security baseline ---
  # Enforce list_db=False (prevent database listing attacks)
  local security_list_db="$list_db"
  if [[ "$security_list_db" == "True" ]]; then
    log_warn "SECURITY: list_db=True is insecure in production — overriding to False"
    security_list_db="False"
  fi

  # Enforce dbfilter if not set or too permissive
  local security_dbfilter="$ODOO_DBFILTER"
  if [[ -z "$security_dbfilter" || "$security_dbfilter" == "^.*$" ]]; then
    security_dbfilter="^${DB_NAME}$"
    log_warn "SECURITY: dbfilter was not set or too permissive — restricting to ^${DB_NAME}$"
  fi

  log_info "writing Odoo config to $ROOT/odoo.conf (workers=$workers, security: list_db=$security_list_db, dbfilter=$security_dbfilter)"
  cat >"$ROOT/odoo.conf" <<EOF
[options]
admin_passwd = $ODOO_ADMIN_PASSWD
db_host = $DB_HOST
db_port = $DB_PORT
db_user = $DB_USER
db_password = $DB_PASSWORD
dbfilter = $security_dbfilter
addons_path = $addons_path
data_dir = $DATA_DIR
http_interface = $ODOO_HTTP_INTERFACE
http_port = $ODOO_HTTP_PORT
gevent_port = $ODOO_GEVENT_PORT
logfile = $LOG_FILE
proxy_mode = $proxy_mode
list_db = $security_list_db
workers = $workers
max_cron_threads = $ODOO_MAX_CRON_THREADS
db_maxconn = $ODOO_DB_MAXCONN
limit_memory_soft = $memory_soft
limit_memory_hard = $memory_hard
limit_time_cpu = $ODOO_LIMIT_TIME_CPU
limit_time_real = $ODOO_LIMIT_TIME_REAL
without_demo = $ODOO_WITHOUT_DEMO
limit_request = 8192
syslog = False
log_db = False
log_db_level = warning
EOF
  chmod 600 "$ROOT/odoo.conf"
  log_info "odoo.conf written with production security baseline applied"
}

# Write the runtime environment file for 'run' command to use later.
# Contains paths and settings needed to launch Odoo without full bootstrap.
write_runtime_env() {
  local tmp
  tmp="$(mktemp "${RUNTIME_ENV_FILE}.XXXXXX")"
  {
    printf "ROOT=%q\n" "$ROOT"
    printf "ODOO_CONF=%q\n" "$ROOT/odoo.conf"
    printf "VENV_DIR=%q\n" "$VENV_DIR"
    printf "ODOO_SRC_DIR=%q\n" "$ODOO_SRC_DIR"
    printf "ODOO_BIN=%q\n" "${ODOO_BIN:-}"
    printf "ODOO_RUNTIME_AUTO_REPAIR=%q\n" "$ODOO_RUNTIME_AUTO_REPAIR"
    printf "ODOO_DEPENDENCY_REPAIR_RETRIES=%q\n" "$ODOO_DEPENDENCY_REPAIR_RETRIES"
    printf "ODOO_DEPENDENCY_REPAIR_RETRY_DELAY=%q\n" "$ODOO_DEPENDENCY_REPAIR_RETRY_DELAY"
    printf "ODOO_HTTP_PORT=%q\n" "$ODOO_HTTP_PORT"
    printf "ODOO_HTTP_INTERFACE=%q\n" "$ODOO_HTTP_INTERFACE"
    printf "ODOO_PID_FILE=%q\n" "$ODOO_PID_FILE"
    printf "DB_NAME=%q\n" "$DB_NAME"
  } >"$tmp"
  mv "$tmp" "$RUNTIME_ENV_FILE"
  chmod 600 "$RUNTIME_ENV_FILE"
  log_debug "runtime env written to $RUNTIME_ENV_FILE"
}
