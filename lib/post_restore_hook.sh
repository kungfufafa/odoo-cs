#!/usr/bin/env bash
# ============================================================================
# post_restore_hook.sh — Fix issues after database restore
# ============================================================================
# Production hardening: ensures restored database is safe and functional
# in a new environment. Disables outgoing mail, external integrations,
# resets URLs, and creates systemd service for auto-start.
# ============================================================================

[[ -n "${_POST_RESTORE_HOOK_LOADED:-}" ]] && return 0
_POST_RESTORE_HOOK_LOADED=1

# Run SQL against the restored application database.
run_db_sql() {
    local sql="$1"
    run_target_psql "$sql"
}

run_db_scalar() {
    local sql="$1"
    run_target_psql "$sql" | tr -d '[:space:]'
}

# Run SQL against the target (non-admin) database using DB_USER credentials.
# This is needed for queries against the restored database.
run_target_db_sql() {
    local sql="$1"
    run_target_psql "$sql" "$DB_NAME"
}

run_target_db_scalar() {
    local sql="$1"
    run_target_db_sql "$sql" | tr -d '[:space:]'
}

# Check if a table exists in the restored database
table_exists() {
    local table="$1"
    local result
    result="$(run_target_db_scalar "SELECT EXISTS (SELECT 1 FROM information_schema.tables WHERE table_schema = 'public' AND table_name = '$table');")"
    [[ "$result" == "t" ]]
}

# ============================================================================
# Database Content Fixes
# ============================================================================

# Disable cron jobs that might cause issues in a new environment
disable_problematic_crons() {
    log_info "Disabling problematic cron jobs..."

    if ! table_exists "ir_cron"; then
        log_debug "ir_cron table not found, skipping"
        return 0
    fi

    local total_disabled=0
    local count

    # 1. Disable all iSeller cron jobs (they require API connection)
    run_target_db_sql "UPDATE ir_cron SET active = false WHERE COALESCE(name, '') ILIKE '%iseller%';" || true
    count="$(run_target_db_scalar "SELECT COUNT(*) FROM ir_cron WHERE active = false AND COALESCE(name, '') ILIKE '%iseller%';")"
    if [[ -n "$count" && "$count" != "0" ]]; then
        log_info "  Disabled $count iSeller cron jobs"
        (( total_disabled += count ))
    fi

    # 2. Disable outgoing email crons (mail.mail, fetchmail, digest, mass_mailing, etc.)
    local mail_patterns=("'%mail%send%'" "'%mail%queue%'" "'%fetchmail%'" "'%digest%'" "'%mass_mailing%'" "'%email%queue%'" "'%newsletter%'")
    for pattern in "${mail_patterns[@]}"; do
        run_target_db_sql "UPDATE ir_cron SET active = false WHERE active = true AND (COALESCE(name, '') ILIKE $pattern OR ir_actions_server_id IN (SELECT id FROM ir_act_server WHERE name::text ILIKE $pattern));" || true
    done
    count="$(run_target_db_scalar "SELECT COUNT(*) FROM ir_cron WHERE active = false AND (COALESCE(name, '') ILIKE '%mail%' OR COALESCE(name, '') ILIKE '%fetchmail%' OR COALESCE(name, '') ILIKE '%digest%');")"
    if [[ -n "$count" && "$count" != "0" ]]; then
        log_info "  Disabled $count mail-related cron jobs"
        (( total_disabled += count ))
    fi

    # 3. Disable external API/webhook crons generically
    local api_patterns=("'%api%'" "'%webhook%'" "'%sync%external%'" "'%export%'" "'%import%auto%'")
    for pattern in "${api_patterns[@]}"; do
        run_target_db_sql "UPDATE ir_cron SET active = false WHERE active = true AND COALESCE(name, '') ILIKE $pattern;" || true
    done

    log_info "Cron neutralization complete (total affected: $total_disabled+)"
}

# Fix ir.rules with invalid field references
fix_invalid_rules() {
    log_info "Fixing invalid ir.rules..."

    if ! table_exists "ir_rule"; then
        log_debug "ir_rule table not found, skipping"
        return 0
    fi

    # Disable rule that references non-existent field operation_type_ids
    local count
    run_target_db_sql "UPDATE ir_rule SET active = false WHERE domain_force::text ILIKE '%operation_type_ids%';" || true
    count="$(run_target_db_scalar "SELECT COUNT(*) FROM ir_rule WHERE active = false AND domain_force::text ILIKE '%operation_type_ids%';")"

    if [[ -n "$count" && "$count" != "0" ]]; then
        log_info "  Disabled $count invalid ir.rules"
    else
        log_debug "  No invalid ir.rules to fix"
    fi
}

# Neutralize outgoing mail servers to prevent accidental emails to customers
neutralize_mail_servers() {
    log_info "Neutralizing outgoing mail servers..."

    if table_exists "ir_mail_server"; then
        local count
        run_target_db_sql "UPDATE ir_mail_server SET active = false;" || true
        count="$(run_target_db_scalar "SELECT COUNT(*) FROM ir_mail_server WHERE active = false;")"
        if [[ -n "$count" && "$count" != "0" ]]; then
            log_info "  Deactivated $count outgoing mail server(s) — re-enable manually when ready"
        fi
    fi

    # Also disable fetchmail servers (incoming mail that triggers replies)
    if table_exists "fetchmail_server"; then
        run_target_db_sql "UPDATE fetchmail_server SET active = false, state = 'draft';" || true
        local count
        count="$(run_target_db_scalar "SELECT COUNT(*) FROM fetchmail_server;")"
        if [[ -n "$count" && "$count" != "0" ]]; then
            log_info "  Deactivated $count incoming mail server(s)"
        fi
    fi
}

# Reset web.base.url to point to the current server
reset_web_base_url() {
    log_info "Resetting web.base.url..."

    if ! table_exists "ir_config_parameter"; then
        log_debug "ir_config_parameter table not found, skipping"
        return 0
    fi

    local port="${ODOO_HTTP_PORT:-8069}"
    local base_url new_base_url

    # Detect the best IP for the URL
    local detected_ip=""
    if command -v hostname >/dev/null 2>&1; then
        detected_ip="$(hostname -I 2>/dev/null | awk '{print $1}' || true)"
    fi
    if [[ -z "$detected_ip" ]] && command -v ip >/dev/null 2>&1; then
        detected_ip="$(ip -4 -o addr show scope global 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | head -n 1 || true)"
    fi
    if [[ -z "$detected_ip" ]] && command -v ifconfig >/dev/null 2>&1; then
        detected_ip="$(ifconfig 2>/dev/null | grep 'inet ' | awk '{print $2}' | grep -v '127\.' | head -n 1 || true)"
    fi
    [[ -z "$detected_ip" ]] && detected_ip="localhost"

    new_base_url="http://${detected_ip}:${port}"

    # Get current value for logging
    base_url="$(run_target_db_scalar "SELECT value FROM ir_config_parameter WHERE key = 'web.base.url';")"
    if [[ -n "$base_url" && "$base_url" != "$new_base_url" ]]; then
        log_info "  Updating web.base.url: $base_url → $new_base_url"
        run_target_db_sql "UPDATE ir_config_parameter SET value = '$new_base_url' WHERE key = 'web.base.url';" || true
        run_target_db_sql "UPDATE ir_config_parameter SET value = '$new_base_url' WHERE key = 'web.base.url.freeze';" || true
    else
        log_debug "  web.base.url already correct or not set"
    fi

    # Also update report.url if it exists
    run_target_db_sql "UPDATE ir_config_parameter SET value = '$new_base_url' WHERE key = 'report.url';" || true
}

# Check and log module states that might need attention
check_module_states() {
    log_info "Checking module states..."

    if ! table_exists "ir_module_module"; then
        log_debug "ir_module_module table not found, skipping"
        return 0
    fi

    # Log modules that need action
    local to_install to_upgrade to_remove

    to_install="$(run_target_db_scalar "SELECT COUNT(*) FROM ir_module_module WHERE state = 'to install';")"
    to_upgrade="$(run_target_db_scalar "SELECT COUNT(*) FROM ir_module_module WHERE state = 'to upgrade';")"
    to_remove="$(run_target_db_scalar "SELECT COUNT(*) FROM ir_module_module WHERE state = 'to remove';")"

    local needs_attention=0
    if [[ -n "$to_install" && "$to_install" != "0" ]]; then
        log_warn "  $to_install module(s) in 'to install' state"
        (( needs_attention++ ))
    fi
    if [[ -n "$to_upgrade" && "$to_upgrade" != "0" ]]; then
        log_warn "  $to_upgrade module(s) in 'to upgrade' state"
        (( needs_attention++ ))
    fi
    if [[ -n "$to_remove" && "$to_remove" != "0" ]]; then
        log_warn "  $to_remove module(s) in 'to remove' state"
        (( needs_attention++ ))
    fi

    if (( needs_attention > 0 )); then
        log_warn "  Modules with pending state detected — Odoo may process them on first startup (this is normal)"
    fi

    # Log installed custom module count
    local installed_count
    installed_count="$(run_target_db_scalar "SELECT COUNT(*) FROM ir_module_module WHERE state = 'installed';")"
    if [[ -n "$installed_count" ]]; then
        log_info "  Total installed modules: $installed_count"
    fi
}

# Disable publisher_warranty ping (phones home to Odoo SA)
disable_publisher_warranty() {
    if table_exists "ir_config_parameter"; then
        run_target_db_sql "UPDATE ir_config_parameter SET value = '' WHERE key = 'publisher_warranty.warranty_url';" || true
        log_debug "  Publisher warranty URL cleared"
    fi
}

# ============================================================================
# System-Level Fixes
# ============================================================================

# Install missing Python dependencies (for system Python)
install_python_deps() {
    log_info "Checking Python dependencies..."

    # Only for deb install mode - check system Python
    if [[ "${INSTALL_MODE:-}" == "deb" ]] && [[ -x "/usr/bin/python3" ]]; then
        if ! /usr/bin/python3 -c "from lxml.html import clean" 2>/dev/null; then
            log_info "Installing lxml_html_clean for system Python..."
            if command -v apt-get >/dev/null 2>&1; then
                apt-get install -y python3-lxml-html-clean 2>/dev/null || \
                /usr/bin/python3 -m pip install --break-system-packages lxml_html_clean 2>/dev/null || \
                log_warn "Could not install lxml_html_clean - may need manual install"
            fi
        else
            log_debug "lxml.html.clean already available"
        fi
    fi
}

pick_browser_login_user() {
    local login_lit result

    if [[ -n "${ODOO_WEB_LOGIN:-}" ]]; then
        login_lit="$(sql_escape_literal "$ODOO_WEB_LOGIN")"
        result="$(run_db_sql "
SELECT id || '|' || login
FROM res_users
WHERE active IS TRUE
  AND COALESCE(login, '') <> ''
  AND login = '$login_lit'
ORDER BY id
LIMIT 1;
")"
        if [[ -n "$result" ]]; then
            printf '%s\n' "$result"
            return 0
        fi

        log_warn "requested ODOO_WEB_LOGIN=$ODOO_WEB_LOGIN was not found in restored database; falling back to auto-detect"
    fi

    result="$(run_db_sql "
WITH candidates AS (
    SELECT
        u.id,
        u.login,
        MAX(CASE WHEN imd.module = 'base' AND imd.name = 'group_system' THEN 1 ELSE 0 END) AS is_system,
        MAX(CASE WHEN imd.module = 'base' AND imd.name = 'group_user' THEN 1 ELSE 0 END) AS is_internal
    FROM res_users u
    LEFT JOIN res_groups_users_rel rel ON rel.uid = u.id
    LEFT JOIN ir_model_data imd ON imd.model = 'res.groups' AND imd.res_id = rel.gid
    WHERE u.active IS TRUE
      AND COALESCE(u.login, '') <> ''
    GROUP BY u.id, u.login
)
SELECT id || '|' || login
FROM candidates
WHERE login = 'admin' OR is_system = 1 OR is_internal = 1
ORDER BY
    CASE WHEN login = 'admin' THEN 0 ELSE 1 END,
    CASE WHEN is_system = 1 THEN 0 ELSE 1 END,
    id
LIMIT 1;
")"

    if [[ -z "$result" ]]; then
        result="$(run_db_sql "
SELECT id || '|' || login
FROM res_users
WHERE active IS TRUE
  AND COALESCE(login, '') <> ''
ORDER BY
    CASE WHEN login = 'admin' THEN 0 ELSE 1 END,
    id
LIMIT 1;
")"
    fi

    [[ -n "$result" ]] || return 1
    printf '%s\n' "$result"
}

reset_browser_login_password() {
    local user_id="$1"
    local user_login="$2"
    local shell_script shell_output

    shell_script="$(mktemp "$RESTORE_WORKDIR/odoo-shell-login-reset.XXXXXX.py")"
    cat >"$shell_script" <<'PY'
import os

user_id = int(os.environ["ODOO_BOOTSTRAP_LOGIN_USER_ID"])
password = os.environ["ODOO_BOOTSTRAP_LOGIN_PASSWORD"]
user = env["res.users"].browse(user_id)
if not user.exists():
    raise SystemExit(f"user {user_id} not found")
user.write({"password": password})
env.cr.commit()
print(user.login)
PY

    if ! shell_output="$(
        export ODOO_BOOTSTRAP_LOGIN_USER_ID="$user_id"
        export ODOO_BOOTSTRAP_LOGIN_PASSWORD="$ODOO_WEB_LOGIN_PASSWORD"
        run_odoo_shell_script "$DB_NAME" "$shell_script" | tail -n 1 | tr -d '\r'
    )"; then
        rm -f "$shell_script"
        log_fatal "failed to reset browser login password for restored user: $user_login"
    fi

    rm -f "$shell_script"
    ODOO_WEB_LOGIN="${shell_output:-$user_login}"
}

ensure_browser_login_access() {
    local user_row user_id user_login

    user_row="$(pick_browser_login_user || true)"
    [[ -n "$user_row" ]] || log_fatal "unable to find an active Odoo user for browser login in restored database"

    user_id="${user_row%%|*}"
    user_login="${user_row#*|}"
    ODOO_WEB_LOGIN="$user_login"

    if [[ "${ODOO_WEB_LOGIN_RESET:-1}" != "1" ]]; then
        write_secrets_file
        log_info "browser login detected: $ODOO_WEB_LOGIN"
        return 0
    fi

    [[ -n "${ODOO_WEB_LOGIN_PASSWORD:-}" ]] || ODOO_WEB_LOGIN_PASSWORD="$(random_secret)"
    log_info "preparing browser login access for restored user: $user_login"
    reset_browser_login_password "$user_id" "$user_login"
    write_secrets_file
    log_info "browser login ready: $ODOO_WEB_LOGIN (password stored in $SECRETS_ENV_FILE)"
}

# Create systemd service for Odoo
path_is_root_only() {
    local path="$1"
    [[ "$path" == "/root" || "$path" == /root/* ]]
}

select_nologin_shell() {
    local candidate
    for candidate in /usr/sbin/nologin /usr/bin/nologin /bin/false; do
        if [[ -x "$candidate" ]]; then
            printf '%s\n' "$candidate"
            return 0
        fi
    done

    printf '/bin/false\n'
}

ensure_service_account() {
    local service_user="${ODOO_SERVICE_USER:-odoo}"
    local service_group="${ODOO_SERVICE_GROUP:-$service_user}"
    local login_shell

    if ! getent group "$service_group" >/dev/null 2>&1; then
        groupadd --system "$service_group" >/dev/null 2>&1 || true
    fi

    if ! id "$service_user" >/dev/null 2>&1; then
        login_shell="$(select_nologin_shell)"
        useradd --system --gid "$service_group" --home-dir "$ROOT" --shell "$login_shell" "$service_user" >/dev/null 2>&1 || \
        useradd --system --gid "$service_group" --shell "$login_shell" "$service_user" >/dev/null 2>&1 || \
        log_warn "Could not create service user $service_user automatically"
    fi
}

prepare_service_runtime_permissions() {
    local service_user="${ODOO_SERVICE_USER:-odoo}"
    local service_group="${ODOO_SERVICE_GROUP:-$service_user}"
    local odoo_conf="${ROOT}/odoo.conf"
    local log_dir

    if path_is_root_only "$ROOT" || path_is_root_only "$DATA_DIR" || path_is_root_only "$LOG_FILE"; then
        log_warn "Skipping systemd service creation because runtime paths are under /root; move deployment to /opt or another shared path for non-root service support"
        return 1
    fi

    log_dir="$(dirname "$LOG_FILE")"
    mkdir -p "$DATA_DIR" "$log_dir"
    touch "$LOG_FILE"

    chown "$service_user:$service_group" "$ROOT" "$log_dir" 2>/dev/null || true
    chmod 750 "$ROOT" "$log_dir" 2>/dev/null || true
    chown -R "$service_user:$service_group" "$DATA_DIR" 2>/dev/null || true
    chown "$service_user:$service_group" "$LOG_FILE" "$odoo_conf" 2>/dev/null || true
    chmod 640 "$LOG_FILE" "$odoo_conf" 2>/dev/null || true

    if [[ -n "${CUSTOM_ADDONS_DIR:-}" && -d "$CUSTOM_ADDONS_DIR" ]]; then
        chown -R "$service_user:$service_group" "$CUSTOM_ADDONS_DIR" 2>/dev/null || true
        chmod -R u+rwX,go-rwx "$CUSTOM_ADDONS_DIR" 2>/dev/null || true

        if [[ "$CUSTOM_ADDONS_DIR" == "$ARTIFACTS_DIR" || "$CUSTOM_ADDONS_DIR" == "$ARTIFACTS_DIR/"* ]]; then
            chown "$service_user:$service_group" "$ARTIFACTS_DIR" 2>/dev/null || true
            chmod 750 "$ARTIFACTS_DIR" 2>/dev/null || true
        fi
    fi

    return 0
}

create_systemd_service() {
    log_info "Creating systemd service..."

    local service_file="/etc/systemd/system/odoo-cs.service"
    local odoo_conf="${ROOT}/odoo.conf"
    local service_user="${ODOO_SERVICE_USER:-odoo}"
    local service_group="${ODOO_SERVICE_GROUP:-$service_user}"
    local exec_start

    # Determine ExecStart based on install mode
    case "${INSTALL_MODE:-}" in
        source)
            if [[ -n "${ODOO_SRC_DIR:-}" && -n "${VENV_DIR:-}" ]]; then
                exec_start="${VENV_DIR}/bin/python ${ODOO_SRC_DIR}/setup/odoo -c ${odoo_conf}"
            else
                log_warn "ODOO_SRC_DIR or VENV_DIR not set, cannot create systemd service for source mode"
                return 0
            fi
            ;;
        deb)
            exec_start="/usr/bin/odoo -c ${odoo_conf}"
            ;;
        *)
            if [[ -n "${ODOO_BIN:-}" ]]; then
                exec_start="${ODOO_BIN} -c ${odoo_conf}"
            elif [[ -x /usr/bin/odoo ]]; then
                exec_start="/usr/bin/odoo -c ${odoo_conf}"
            else
                log_warn "Cannot determine Odoo executable for systemd service"
                return 0
            fi
            ;;
    esac

    ensure_service_account
    prepare_service_runtime_permissions || return 0

    # Give service user read access to ROOT dir for source mode
    if [[ "${INSTALL_MODE:-}" == "source" ]]; then
        chown -R "$service_user:$service_group" "$ROOT" 2>/dev/null || true
    fi

    cat > "$service_file" << EOF
[Unit]
Description=Odoo CS (Community Setup)
After=postgresql.service
Requires=postgresql.service

[Service]
Type=simple
User=${service_user}
Group=${service_group}
WorkingDirectory=${ROOT}
Environment="ROOT=${ROOT}"
Environment="HOME=${DATA_DIR}"
ExecStart=${exec_start}
ExecReload=/bin/kill -HUP \$MAINPID
Restart=always
RestartSec=10
KillMode=mixed
KillSignal=SIGTERM
TimeoutStopSec=30
StandardOutput=append:${ROOT}/odoo.log
StandardError=append:${ROOT}/odoo.log

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable odoo-cs 2>/dev/null || true
    systemctl start odoo-cs 2>/dev/null || true

    log_info "Systemd service created and started: odoo-cs.service"
}

# Validate database schema
validate_database_schema() {
    log_info "Validating database schema..."

    local required_tables="ir_cron ir_act_server ir_rule ir_module_module res_users"
    local missing=0

    for table in $required_tables; do
        if ! table_exists "$table"; then
            log_warn "Missing table: $table"
            ((missing++))
        fi
    done

    if [[ $missing -gt 0 ]]; then
        log_warn "Schema validation: $missing missing tables"
        return 1
    fi

    log_info "Schema validation passed ✓"
    return 0
}

# Disable conflicting services
disable_conflicting_services() {
    log_info "Disabling conflicting services..."

    command -v systemctl >/dev/null 2>&1 || return 0

    if systemctl is-enabled odoo.service 2>/dev/null; then
        systemctl stop odoo.service 2>/dev/null || true
        systemctl disable odoo.service 2>/dev/null || true
        log_info "Disabled default odoo.service"
    fi
}

# Fix directory permissions
fix_permissions() {
    log_info "Fixing permissions..."

    if [[ -n "$DATA_DIR" ]]; then
        mkdir -p "$DATA_DIR" 2>/dev/null || true
        chmod 755 "$DATA_DIR" 2>/dev/null || true

        if [[ -d "$DATA_DIR/filestore/$DB_NAME" ]]; then
            chmod -R 755 "$DATA_DIR/filestore/$DB_NAME" 2>/dev/null || true
        fi
    fi
}

# Open firewall port for Odoo HTTP access
open_firewall_port() {
    local port="${ODOO_HTTP_PORT:-8069}"

    if [[ "${ODOO_EXPOSE_HTTP:-0}" != "1" ]]; then
        log_debug "ODOO_EXPOSE_HTTP is not 1, skipping firewall configuration"
        return 0
    fi

    # Try ufw first (Ubuntu/Debian)
    if command -v ufw >/dev/null 2>&1; then
        if ufw status 2>/dev/null | grep -qi 'active'; then
            log_info "Opening firewall port $port via ufw"
            ufw allow "$port/tcp" 2>/dev/null || log_warn "Failed to open port $port via ufw"
            return 0
        fi
    fi

    # Try firewall-cmd (CentOS/RHEL)
    if command -v firewall-cmd >/dev/null 2>&1; then
        if firewall-cmd --state 2>/dev/null | grep -qi 'running'; then
            log_info "Opening firewall port $port via firewall-cmd"
            firewall-cmd --permanent --add-port="$port/tcp" 2>/dev/null || true
            firewall-cmd --reload 2>/dev/null || true
            return 0
        fi
    fi

    # Try iptables as last resort
    if command -v iptables >/dev/null 2>&1; then
        if ! iptables -C INPUT -p tcp --dport "$port" -j ACCEPT 2>/dev/null; then
            log_info "Opening firewall port $port via iptables"
            iptables -I INPUT -p tcp --dport "$port" -j ACCEPT 2>/dev/null || true
        fi
    fi

    log_debug "No active firewall detected or port already open"
}

# ============================================================================
# Main Post-Restore Orchestrator
# ============================================================================

# Auto-install custom modules by registering them in ir_module_module.
# This makes Odoo detect modules without requiring a manual UI click.
# Arguments: $1=addons directory
auto_install_custom_modules() {
    local addons_dir="$1"
    local auto_install="${FETCH_START_AUTO_INSTALL_MODULES:-1}"

    if [[ "$auto_install" != "1" ]]; then
        log_info "Module auto-install disabled (FETCH_START_AUTO_INSTALL_MODULES=0)"
        return 0
    fi

    if [[ ! -d "$addons_dir" ]]; then
        log_debug "No custom addons directory to scan"
        return 0
    fi

    if ! table_exists "ir_module_module"; then
        log_debug "ir_module_module table not found — skipping module auto-install"
        return 0
    fi

    log_info "Scanning custom addons for auto-installation..."

    local module_dir manifest technical_name
    local updated=0 already_installed=0

    while IFS= read -r manifest; do
        module_dir="$(dirname "$manifest")"
        technical_name="$(basename "$module_dir")"

        # Get the module name from manifest
        if ! command -v python3 >/dev/null 2>&1; then
            continue
        fi

        # Check if module already exists in ir_module_module
        local exists state
        local escaped_name
        escaped_name="$(sql_escape_literal "$technical_name")"
        exists="$(run_target_db_scalar "SELECT COUNT(*) FROM ir_module_module WHERE name = '$escaped_name';" 2>/dev/null || echo "0")"

        if [[ "$exists" == "0" ]]; then
            # Insert new module record so Odoo can detect it
            run_target_db_sql "INSERT INTO ir_module_module (name, state, latest_version, installed_version, create_uid, write_uid, create_date, write_date) VALUES ('$escaped_name', 'uninstalled', NULL, NULL, 1, 1, NOW(), NOW()) ON CONFLICT (name) DO NOTHING;" 2>/dev/null || true
            (( updated++ ))
            log_info "  Registered new module: $technical_name"
        else
            state="$(run_target_db_scalar "SELECT state FROM ir_module_module WHERE name = '$escaped_name';" 2>/dev/null || echo "unknown")"
            if [[ "$state" == "installed" ]]; then
                (( already_installed++ ))
            else
                log_info "  Module found: $technical_name — state: $state"
                (( updated++ ))
            fi
        fi
    done < <(find "$addons_dir" -maxdepth 2 -name '__manifest__.py' 2>/dev/null)

    log_info "Module auto-install scan: $updated registered/updated, $already_installed already installed"
}

run_post_restore_hooks() {
    log_info "╔══════════════════════════════════════════════════════╗"
    log_info "║         Running post-restore hooks...              ║"
    log_info "╚══════════════════════════════════════════════════════╝"

    # 1. Validate schema first
    validate_database_schema || log_warn "Schema validation had issues — proceeding anyway"

    # 2. Critical safety: neutralize outgoing communications
    neutralize_mail_servers
    disable_problematic_crons

    # 3. Fix database content
    fix_invalid_rules
    reset_web_base_url
    disable_publisher_warranty
    check_module_states

    # 4. Module verification and auto-install
    if [[ -n "${CUSTOM_ADDONS_DIR:-}" && -d "${CUSTOM_ADDONS_DIR:-}" ]]; then
        auto_install_custom_modules "$CUSTOM_ADDONS_DIR"
    fi

    # 5. System-level fixes
    fix_permissions
    install_python_deps
    if [[ -n "${ODOO_BIN:-}" || -n "${ODOO_SRC_DIR:-}" ]]; then
        ensure_browser_login_access
    else
        log_warn "Odoo binary not available yet — skipping browser login password reset"
    fi
    disable_conflicting_services

    # 6. Firewall (root only)
    if [[ "$(id -u)" == "0" ]]; then
        open_firewall_port
    fi

    # 7. Create systemd service (root on Linux, any install mode)
    if [[ "$(id -u)" == "0" ]] && command -v systemctl >/dev/null 2>&1; then
        create_systemd_service
    fi

    log_info "Post-restore hooks completed ✓"
}
