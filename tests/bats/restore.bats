#!/usr/bin/env bats
# ============================================================================
# restore.bats — Unit tests for lib/restore.sh
# ============================================================================

load test_helper

setup() {
  setup_test_environment
  load_module "platform.sh"
  load_module "install.sh"
  load_module "validation.sh"
  load_module "restore.sh"
}

teardown() {
  teardown_test_environment
}

# --- generate_restore_temp_db_name ------------------------------------------

@test "generate_restore_temp_db_name respects PostgreSQL identifier length" {
  export DB_NAME="$(printf 'a%.0s' $(seq 1 63))"
  local result
  result="$(generate_restore_temp_db_name "staging")"
  (( ${#result} <= 63 ))
}

# --- restore_with_refresh_strategy ------------------------------------------

@test "restore_with_refresh_strategy restores staging DB before replacing target" {
  local calls_file="$TEST_TMP/restore_calls.txt"

  generate_restore_temp_db_name() { printf 'test_db_staging'; }
  drop_database_named_if_exists() { printf 'drop:%s\n' "$1" >>"$calls_file"; }
  drop_database_if_exists() { printf 'drop:%s\n' "$DB_NAME" >>"$calls_file"; }
  create_database_named_if_missing() { printf 'create:%s:%s\n' "$1" "$2" >>"$calls_file"; }
  rollback_register() { printf 'rollback:%s\n' "$1" >>"$calls_file"; }
  restore_payload_into_database() { printf 'restore:%s:%s\n' "$3" "$2" >>"$calls_file"; }
  db_exists() { printf 'exists:%s\n' "$DB_NAME" >>"$calls_file"; return 0; }
  rename_database() { printf 'rename:%s:%s\n' "$1" "$2" >>"$calls_file"; }

  restore_with_refresh_strategy "plain" "$ROOT/dump.sql"

  [ "$(sed -n '1p' "$calls_file")" = "drop:test_db_staging" ]
  [ "$(sed -n '2p' "$calls_file")" = "create:test_db_staging:test_user" ]
  [ "$(sed -n '3p' "$calls_file")" = "rollback:drop temporary restore database test_db_staging" ]
  [ "$(sed -n '4p' "$calls_file")" = "restore:test_db_staging:$ROOT/dump.sql" ]
  [ "$(sed -n '5p' "$calls_file")" = "exists:test_db" ]
  [ "$(sed -n '6p' "$calls_file")" = "drop:test_db" ]
  [ "$(sed -n '7p' "$calls_file")" = "rename:test_db_staging:test_db" ]
}

@test "detect_backup_input ignores internal restore workspace dumps" {
  mkdir -p "$RESTORE_WORKDIR/stale" "$ROOT/incoming"
  touch "$RESTORE_WORKDIR/stale/dump.sql"
  touch "$ROOT/incoming/dump.sql"

  result="$(detect_backup_input)"

  [ "$result" = "$ROOT/incoming" ]
}

@test "detect_backup_input detects zip backup with python fallback when unzip is unavailable" {
  python3 - <<PY
import pathlib
import zipfile

root = pathlib.Path(r"$ROOT")
with zipfile.ZipFile(root / "db-backup.zip", "w") as archive:
    archive.writestr("dump.sql", "-- test dump\n")
    archive.writestr("filestore/.keep", "")
PY

  command() {
    if [[ "$1" == "-v" && "$2" == "unzip" ]]; then
      return 1
    fi
    builtin command "$@"
  }

  result="$(detect_backup_input)"

  [ "$result" = "$ROOT/db-backup.zip" ]
}

@test "restore_payload_into_database fails when plain SQL restore exits non-zero" {
  export PATH="$MOCK_BIN:$PATH"
  cat >"$MOCK_BIN/psql" <<'EOF'
#!/usr/bin/env bash
printf 'psql:dump.sql:1: ERROR: restore failed\n' >&2
exit 3
EOF
  chmod +x "$MOCK_BIN/psql"
  touch "$ROOT/dump.sql"

  run restore_payload_into_database plain "$ROOT/dump.sql" "$DB_NAME"

  [ "$status" -ne 0 ]
  [[ "$output" == *"plain SQL restore failed"* ]]
}

@test "restore_payload_into_database uses strict pg_restore flags" {
  export PATH="$MOCK_BIN:$PATH"
  cat >"$MOCK_BIN/pg_restore" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >"$ROOT/pg_restore_args.txt"
EOF
  chmod +x "$MOCK_BIN/pg_restore"
  touch "$ROOT/backup.dump"

  _validate_core_tables_after_restore() {
    return 0
  }

  run restore_payload_into_database custom "$ROOT/backup.dump" "$DB_NAME"

  [ "$status" -eq 0 ]
  grep -q -- '--no-privileges' "$ROOT/pg_restore_args.txt"
  grep -q -- '--exit-on-error' "$ROOT/pg_restore_args.txt"
}

@test "restore module avoids bash-4-only associative arrays" {
  run grep -n 'declare -A' "$PROJECT_ROOT/lib/restore.sh"

  [ "$status" -ne 0 ]
}
