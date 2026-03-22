#!/usr/bin/env bats
# ============================================================================
# secrets.bats — Unit tests for lib/secrets.sh
# ============================================================================

load test_helper

setup() {
  setup_test_environment
  export OS_FAMILY="linux"
  load_module "platform.sh"
  load_module "secrets.sh"
}

teardown() {
  teardown_test_environment
}

# --- random_secret ----------------------------------------------------------

@test "random_secret generates 32-character string" {
  local secret
  secret="$(random_secret)"
  [ "${#secret}" -eq 32 ]
}

@test "random_secret generates different values each call" {
  local s1 s2
  s1="$(random_secret)"
  s2="$(random_secret)"
  [ "$s1" != "$s2" ]
}

@test "random_secret contains only alphanumeric and safe chars" {
  local secret
  secret="$(random_secret)"
  [[ "$secret" =~ ^[A-Za-z0-9/+=]+$ ]] || [[ "$secret" =~ ^[A-Za-z0-9]+$ ]]
}

# --- write_secrets_file -----------------------------------------------------

@test "write_secrets_file creates file" {
  write_secrets_file
  [ -f "$SECRETS_ENV_FILE" ]
}

@test "write_secrets_file sets chmod 600" {
  write_secrets_file
  local perms
  perms="$(stat -f '%Lp' "$SECRETS_ENV_FILE" 2>/dev/null || stat -c '%a' "$SECRETS_ENV_FILE")"
  [ "$perms" = "600" ]
}

@test "write_secrets_file contains DB_PASSWORD" {
  export DB_PASSWORD="test_secret_123"
  write_secrets_file
  grep -q "DB_PASSWORD" "$SECRETS_ENV_FILE"
}

@test "write_secrets_file contains ODOO_ADMIN_PASSWD" {
  export ODOO_ADMIN_PASSWD="admin_secret_456"
  write_secrets_file
  grep -q "ODOO_ADMIN_PASSWD" "$SECRETS_ENV_FILE"
}

# --- ensure_secrets ---------------------------------------------------------

@test "ensure_secrets generates password if empty" {
  export DB_PASSWORD=""
  export ODOO_ADMIN_PASSWD=""
  export ORIGINAL_DB_PASSWORD="__unset__"
  export ORIGINAL_ODOO_ADMIN_PASSWD="__unset__"
  ensure_secrets
  [ -n "$DB_PASSWORD" ]
  [ -n "$ODOO_ADMIN_PASSWD" ]
}

@test "ensure_secrets preserves existing password" {
  export DB_PASSWORD="my_existing_password"
  export ODOO_ADMIN_PASSWD="my_existing_admin"
  export ORIGINAL_DB_PASSWORD="__unset__"
  export ORIGINAL_ODOO_ADMIN_PASSWD="__unset__"
  ensure_secrets
  [ "$DB_PASSWORD" = "my_existing_password" ]
  [ "$ODOO_ADMIN_PASSWD" = "my_existing_admin" ]
}

@test "ensure_secrets creates secrets file" {
  export DB_PASSWORD=""
  export ODOO_ADMIN_PASSWD=""
  export ORIGINAL_DB_PASSWORD="__unset__"
  export ORIGINAL_ODOO_ADMIN_PASSWD="__unset__"
  ensure_secrets
  [ -f "$SECRETS_ENV_FILE" ]
}

# --- load_persisted_secrets -------------------------------------------------

@test "load_persisted_secrets loads from file" {
  printf "DB_PASSWORD=%q\n" "loaded_password" > "$SECRETS_ENV_FILE"
  printf "ODOO_ADMIN_PASSWD=%q\n" "loaded_admin" >> "$SECRETS_ENV_FILE"
  chmod 600 "$SECRETS_ENV_FILE"
  export ORIGINAL_DB_PASSWORD="__unset__"
  export ORIGINAL_ODOO_ADMIN_PASSWD="__unset__"
  load_persisted_secrets
  [ "$DB_PASSWORD" = "loaded_password" ]
  [ "$ODOO_ADMIN_PASSWD" = "loaded_admin" ]
}

@test "load_persisted_secrets env override takes precedence" {
  printf "DB_PASSWORD=%q\n" "file_password" > "$SECRETS_ENV_FILE"
  chmod 600 "$SECRETS_ENV_FILE"
  export ORIGINAL_DB_PASSWORD="env_override_password"
  load_persisted_secrets
  [ "$DB_PASSWORD" = "env_override_password" ]
}
