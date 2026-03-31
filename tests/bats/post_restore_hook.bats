#!/usr/bin/env bats
# ============================================================================
# post_restore_hook.bats — Unit tests for lib/post_restore_hook.sh
# ============================================================================

load test_helper

setup() {
  setup_test_environment
  export OS_FAMILY="linux"
  export LINUX_DISTRO="ubuntu"
  load_module "platform.sh"
  load_module "database.sh"
  load_module "secrets.sh"
  load_module "service.sh"
  # shellcheck source=/dev/null
  source "$PROJECT_ROOT/lib/post_restore_hook.sh"
}

teardown() {
  teardown_test_environment
}

@test "run_db_sql targets the restored application database" {
  run_target_psql() {
    printf '%s\n' "$1" >"$ROOT/post-restore-sql.txt"
  }

  run run_db_sql "SELECT 1;"

  [ "$status" -eq 0 ]
  [ "$(cat "$ROOT/post-restore-sql.txt")" = "SELECT 1;" ]
}

@test "disable_problematic_crons filters by ir_cron.name" {
  table_exists() {
    return 0
  }
  run_target_db_sql() {
    printf '%s\n' "$1" >"$ROOT/cron-sql.txt"
  }
  run_target_db_scalar() {
    printf '1\n'
  }

  run disable_problematic_crons

  [ "$status" -eq 0 ]
  grep -q "COALESCE(name, '') ILIKE '%iseller%'" "$ROOT/cron-sql.txt"
}

@test "ensure_browser_login_access resets a known browser login and persists it" {
  export ODOO_WEB_LOGIN_PASSWORD="browser_password_123456"
  export ODOO_WEB_LOGIN_RESET="1"

  run_db_sql() {
    case "$1" in
      *"WITH candidates AS"*)
        printf '7|admin\n'
        ;;
      *)
        return 1
        ;;
    esac
  }

  run_odoo_shell_script() {
    printf '%s|%s\n' "$ODOO_BOOTSTRAP_LOGIN_USER_ID" "$ODOO_BOOTSTRAP_LOGIN_PASSWORD" >"$ROOT/odoo-shell-env.txt"
    printf 'admin\n'
  }

  write_secrets_file() {
    printf '%s|%s\n' "$ODOO_WEB_LOGIN" "$ODOO_WEB_LOGIN_PASSWORD" >"$ROOT/browser-secrets.txt"
  }

  run ensure_browser_login_access

  [ "$status" -eq 0 ]
  [ "$(cat "$ROOT/odoo-shell-env.txt")" = "7|browser_password_123456" ]
  [ "$(cat "$ROOT/browser-secrets.txt")" = "admin|browser_password_123456" ]
}

@test "prepare_service_runtime_permissions grants access to addons under artifacts" {
  local calls_file="$ROOT/service-permissions.txt"
  export CUSTOM_ADDONS_DIR="$ARTIFACTS_DIR/custom-addons"
  mkdir -p "$CUSTOM_ADDONS_DIR" "$DATA_DIR"

  chown() {
    printf 'chown:%s\n' "$*" >>"$calls_file"
  }

  chmod() {
    printf 'chmod:%s\n' "$*" >>"$calls_file"
  }

  touch() {
    :
  }

  run prepare_service_runtime_permissions

  [ "$status" -eq 0 ]
  grep -q "$ROOT" "$calls_file"
  grep -q "$ARTIFACTS_DIR" "$calls_file"
  grep -q "$CUSTOM_ADDONS_DIR" "$calls_file"
}
