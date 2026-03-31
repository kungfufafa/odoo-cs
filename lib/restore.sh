#!/usr/bin/env bash
# ============================================================================
# restore.sh — Backup detection and database restore operations
# ============================================================================
# Supports: plain SQL dump, PostgreSQL custom dump, zip archives containing
# dumps and filestores. Handles restore strategies (refresh/reuse/fail) and
# filestore synchronization (mirror/merge/skip).
# ============================================================================

[[ -n "${_RESTORE_SH_LOADED:-}" ]] && return 0
_RESTORE_SH_LOADED=1

# Find user-provided files while excluding workspace-managed directories.
# Arguments: $1=maxdepth, remaining args=additional find predicates
_find_user_workspace_files() {
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
       -o -path "$ROOT/.git" -o -path "$ROOT/.git/*" \) -prune -o \
    -type f "$@" -print
}

# Detect backup input automatically by searching for dump files and archives.
# Output: backup input path on stdout
# Returns: 0 if found, 1 if not found
detect_backup_input() {
  local candidate zip_candidate
  [[ -n "$BACKUP_INPUT" ]] && {
    printf '%s\n' "$BACKUP_INPUT"
    return 0
  }

  # Look for dump.sql in subdirectories
  candidate="$(_find_user_workspace_files 3 -name 'dump.sql' | sort | head -n 1 || true)"
  [[ -n "$candidate" ]] && {
    printf '%s\n' "$(dirname "$candidate")"
    return 0
  }

  # Look for zip files containing dumps
  while IFS= read -r zip_candidate; do
    if zip_list_entries "$zip_candidate" 2>/dev/null | grep -Eq '(^|/)dump\.sql$|(^|/).+\.(dump|backup)$'; then
      printf '%s\n' "$zip_candidate"
      return 0
    fi
  done < <(_find_user_workspace_files 2 -name '*.zip' | sort)

  # Look for standalone dump files
  candidate="$(_find_user_workspace_files 2 \( -name '*.dump' -o -name '*.backup' -o -name '*.sql' \) | sort | head -n 1 || true)"
  [[ -n "$candidate" ]] && {
    printf '%s\n' "$candidate"
    return 0
  }

  return 1
}

# Resolve backup input to a working directory containing the dump files.
# Extracts zip/archive inputs if needed.
# Arguments: $1=backup input path (file or directory)
# Output: resolved directory path on stdout
resolve_backup_dir() {
  local input="$1"
  local extract_dir

  [[ -d "$input" ]] && {
    printf '%s\n' "$input"
    return 0
  }

  case "$input" in
    *.zip)
      extract_dir="$RESTORE_WORKDIR/$(basename "${input%.zip}")"
      if [[ ! -f "$extract_dir/.extracted.ok" ]]; then
        rm -rf "$extract_dir"
        mkdir -p "$extract_dir"
        log_info "extracting backup zip to $extract_dir"
        extract_zip_archive "$input" "$extract_dir"
        touch "$extract_dir/.extracted.ok"
      fi
      printf '%s\n' "$extract_dir"
      ;;
    *.sql)
      extract_dir="$RESTORE_WORKDIR/sql_only"
      mkdir -p "$extract_dir"
      ln -sf "$input" "$extract_dir/dump.sql"
      printf '%s\n' "$extract_dir"
      ;;
    *.dump|*.backup)
      extract_dir="$RESTORE_WORKDIR/custom_dump"
      mkdir -p "$extract_dir"
      ln -sf "$input" "$extract_dir/$(basename "$input")"
      printf '%s\n' "$extract_dir"
      ;;
    *)
      log_fatal "unsupported backup input: $input"
      ;;
  esac
}

# Find the restore payload (dump file) within a backup directory.
# Output: "format|filepath" on stdout (format: plain|custom)
# Returns: 0 if found, 1 if not found
find_restore_payload() {
  local backup_dir="$1"
  local dump_sql custom_dump

  dump_sql="$(find "$backup_dir" -type f -name 'dump.sql' | sort | head -n 1 || true)"
  if [[ -n "$dump_sql" ]]; then
    printf 'plain|%s\n' "$dump_sql"
    return 0
  fi

  custom_dump="$(find "$backup_dir" -type f \( -name '*.dump' -o -name '*.backup' \) | sort | head -n 1 || true)"
  if [[ -n "$custom_dump" ]]; then
    printf 'custom|%s\n' "$custom_dump"
    return 0
  fi

  # Check for directory-format dump (pg_restore -Fd)
  local dir_dump
  dir_dump="$(find "$backup_dir" -maxdepth 2 -type f -name 'toc.dat' | sort | head -n 1 || true)"
  if [[ -n "$dir_dump" ]]; then
    printf 'directory|%s\n' "$(dirname "$dir_dump")"
    return 0
  fi

  return 1
}

# Synchronize a filestore directory to the data directory.
# Strategy controlled by FILESTORE_STRATEGY (mirror|merge|skip).
# Arguments: $1=source directory, $2=target directory
mirror_filestore() {
  local source_dir="$1"
  local target_dir="$2"
  require_cmd rsync

  case "$FILESTORE_STRATEGY" in
    skip)
      log_info "skipping filestore sync because FILESTORE_STRATEGY=skip"
      ;;
    merge)
      mkdir -p "$target_dir"
      log_info "merging filestore from $source_dir to $target_dir"
      rsync -a "$source_dir/" "$target_dir/"
      ;;
    mirror)
      mkdir -p "$target_dir"
      log_info "mirroring filestore from $source_dir to $target_dir"
      rsync -a --delete "$source_dir/" "$target_dir/"
      ;;
    *)
      log_fatal "unsupported FILESTORE_STRATEGY: $FILESTORE_STRATEGY"
      ;;
  esac
}

# Generate a temporary database name for staging restores.
# Arguments: $1=label suffix
# Output: database name on stdout
generate_restore_temp_db_name() {
  local label="$1"
  local suffix="_${label}_$$_${SECONDS}"
  local max_prefix_len=$(( 63 - ${#suffix} ))
  local prefix="$DB_NAME"

  if (( max_prefix_len < 1 )); then
    max_prefix_len=1
  fi
  if (( ${#prefix} > max_prefix_len )); then
    prefix="${prefix:0:max_prefix_len}"
  fi

  printf '%s%s\n' "$prefix" "$suffix"
}

_log_restore_output_tail() {
  local label="$1"
  local output_file="$2"

  [[ -f "$output_file" ]] || return 0
  tail -n 50 "$output_file" | while IFS= read -r line; do
    log_debug "$label: $line"
  done
}

run_restore_command_logged() {
  local label="$1"
  shift

  local output_file exit_code=0
  mkdir -p "$RESTORE_WORKDIR"
  output_file="$(mktemp "${RESTORE_WORKDIR}/${label}.XXXXXX.log")"

  if "$@" >"$output_file" 2>&1; then
    exit_code=0
  else
    exit_code=$?
  fi

  _log_restore_output_tail "$label" "$output_file"

  if (( exit_code != 0 )); then
    log_error "$label failed during restore with exit code $exit_code"
    rm -f "$output_file"
    return "$exit_code"
  fi

  rm -f "$output_file"
}

_warn_if_table_below_min_rows() {
  local target_db="$1"
  local table_name="$2"
  local min_rows="$3"
  local actual_rows

  actual_rows="$(PGPASSWORD="$DB_PASSWORD" psql -h "$DB_HOST" -p "$DB_PORT" -U "$DB_USER" -d "$target_db" -Atqc "SELECT COUNT(*) FROM $table_name;" 2>/dev/null | tr -d ' ' || echo "0")"
  if [[ "$actual_rows" =~ ^[0-9]+$ ]] && (( actual_rows < min_rows )); then
    log_warn "table $table_name has only $actual_rows records (expected at least $min_rows) — backup may be incomplete"
  fi
}

# Validate that core Odoo tables exist after restore and have minimum record counts.
# Arguments: $1=target database
# Returns 0 if all critical tables exist and have data, 1 otherwise.
_validate_core_tables_after_restore() {
  local target_db="$1"
  local core_tables="ir_module_module res_users ir_cron ir_config_parameter"
  local table missing=0 empty_tables=0

  for table in $core_tables; do
    local result count
    result="$(PGPASSWORD="$DB_PASSWORD" psql -h "$DB_HOST" -p "$DB_PORT" -U "$DB_USER" -d "$target_db" -Atqc \
      "SELECT EXISTS (SELECT 1 FROM information_schema.tables WHERE table_schema='public' AND table_name='$table');" 2>/dev/null || echo "f")"
    if [[ "$result" != "t" ]]; then
      log_error "core table missing after restore: $table"
      (( missing++ ))
      continue
    fi
    # Check record count (warn if suspiciously empty, but don't fail on all)
    count="$(PGPASSWORD="$DB_PASSWORD" psql -h "$DB_HOST" -p "$DB_PORT" -U "$DB_USER" -d "$target_db" -Atqc "SELECT COUNT(*) FROM $table;" 2>/dev/null | tr -d ' ' || echo "0")"
    if [[ "$count" == "0" ]]; then
      log_warn "core table $table exists but has 0 records"
      (( empty_tables++ ))
    fi
  done

  if (( missing > 0 )); then
    log_error "restore validation failed: $missing core table(s) missing"
    return 1
  fi

  # Verify minimum record counts for critical tables
  _warn_if_table_below_min_rows "$target_db" "ir_module_module" 10
  _warn_if_table_below_min_rows "$target_db" "res_users" 1

  # Count total tables for verification
  local total_tables
  total_tables="$(PGPASSWORD="$DB_PASSWORD" psql -h "$DB_HOST" -p "$DB_PORT" -U "$DB_USER" -d "$target_db" -Atqc "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema='public';" 2>/dev/null | tr -d ' ' || echo "0")"
  log_info "restore validation passed: all core tables present, $total_tables total tables, $empty_tables empty"
  return 0
}

# Restore the selected dump payload into a specific database.
# Arguments: $1=format (plain|custom), $2=restore file, $3=target database
restore_payload_into_database() {
  local format="$1"
  local restore_file="$2"
  local target_db="$3"

  # Detect actual format if labeled as "custom" but is actually a directory
  if [[ "$format" == "custom" && -d "$restore_file" ]]; then
    log_info "detected directory-format dump: $restore_file"
    format="directory"
  fi

  case "$format" in
    plain)
      require_cmd psql
      log_info "restoring plain SQL dump into $target_db: $restore_file"
      # Try strict mode first; if it fails (common with production dumps that
      # have CREATE ROLE, ALTER OWNER, etc.), drop the partially restored DB,
      # recreate it, and retry in tolerant mode.
      if ! run_restore_command_logged "psql-strict" env PGPASSWORD="$DB_PASSWORD" \
        psql -v ON_ERROR_STOP=1 -h "$DB_HOST" -p "$DB_PORT" -U "$DB_USER" -d "$target_db" -f "$restore_file" 2>/dev/null; then
        log_warn "strict SQL restore failed (likely role/owner mismatch) — resetting DB and retrying in tolerant mode"
        # Reset: drop and recreate the target database to avoid mixed state
        PGPASSWORD="$DB_PASSWORD" psql -h "$DB_HOST" -p "$DB_PORT" -U "$DB_USER" -d postgres -Atqc \
          "DROP DATABASE IF EXISTS \"$target_db\";" 2>/dev/null || true
        PGPASSWORD="$DB_PASSWORD" psql -h "$DB_HOST" -p "$DB_PORT" -U "$DB_USER" -d postgres -Atqc \
          "CREATE DATABASE \"$target_db\" OWNER \"$DB_USER\";" 2>/dev/null || \
          log_fatal "could not recreate database $target_db for tolerant retry"
        run_restore_command_logged "psql-tolerant" env PGPASSWORD="$DB_PASSWORD" \
          psql -h "$DB_HOST" -p "$DB_PORT" -U "$DB_USER" -d "$target_db" -f "$restore_file" || \
          log_fatal "plain SQL restore failed for $restore_file"
      fi

      # Post-restore validation: ensure core tables exist
      _validate_core_tables_after_restore "$target_db" || \
        log_fatal "database restore appears to have failed — core Odoo tables are missing from $target_db"
      ;;
    custom)
      require_cmd pg_restore
      log_info "restoring PostgreSQL custom dump into $target_db: $restore_file"
      # --no-owner/--no-privileges avoids common role/ACL mismatches.
      # No --exit-on-error: pg_restore exit code 1 with warnings is acceptable
      # for role/ACL mismatches. Core table validation catches real failures.
      run_restore_command_logged "pg_restore" env PGPASSWORD="$DB_PASSWORD" \
        pg_restore --no-owner --no-privileges --role="$DB_USER" -h "$DB_HOST" -p "$DB_PORT" -U "$DB_USER" -d "$target_db" "$restore_file" || true

      _validate_core_tables_after_restore "$target_db" || \
        log_fatal "database restore appears to have failed — core Odoo tables are missing from $target_db"
      ;;
    directory)
      require_cmd pg_restore
      log_info "restoring PostgreSQL directory-format dump into $target_db: $restore_file"
      run_restore_command_logged "pg_restore" env PGPASSWORD="$DB_PASSWORD" \
        pg_restore --no-owner --no-privileges --role="$DB_USER" -h "$DB_HOST" -p "$DB_PORT" -U "$DB_USER" -d "$target_db" -j 2 "$restore_file" || true

      _validate_core_tables_after_restore "$target_db" || \
        log_fatal "database restore appears to have failed — core Odoo tables are missing from $target_db"
      ;;
    *)
      log_fatal "unsupported restore format: $format"
      ;;
  esac
}

# Refresh strategy: restore into a temporary database, then swap it into place.
# This avoids dropping the target database before the dump is proven restorable.
# Arguments: $1=format (plain|custom), $2=restore file
restore_with_refresh_strategy() {
  local format="$1"
  local restore_file="$2"
  local staging_db
  staging_db="$(generate_restore_temp_db_name "staging")"

  drop_database_named_if_exists "$staging_db"
  create_database_named_if_missing "$staging_db" "$DB_USER"

  if declare -f rollback_register >/dev/null 2>&1; then
    rollback_register "drop temporary restore database $staging_db" "drop_database_named_if_exists '$staging_db'"
  fi

  restore_payload_into_database "$format" "$restore_file" "$staging_db"

  if db_exists; then
    drop_database_if_exists
  fi
  rename_database "$staging_db" "$DB_NAME"
}

# Main restore orchestration function.
# Detects backup input, resolves it, validates strategies, restores DB and filestore.
restore_database() {
  local backup_input backup_dir payload format restore_file
  local filestore_dir target_filestore

  # Validate strategies
  validate_enum "RESTORE_MODE" "$RESTORE_MODE" required auto skip || log_fatal "unsupported RESTORE_MODE: $RESTORE_MODE"
  validate_enum "RESTORE_STRATEGY" "$RESTORE_STRATEGY" refresh reuse fail || log_fatal "unsupported RESTORE_STRATEGY: $RESTORE_STRATEGY"

  if [[ "$RESTORE_MODE" == "skip" ]]; then
    log_info "skipping restore because RESTORE_MODE=skip"
    return 0
  fi

  if ! backup_input="$(detect_backup_input)"; then
    if [[ "$RESTORE_MODE" == "auto" ]]; then
      log_info "no backup detected; skipping restore"
      return 0
    fi
    log_fatal "unable to auto-detect backup input"
  fi

  BACKUP_INPUT="$backup_input"
  backup_dir="$(resolve_backup_dir "$backup_input")"
  payload="$(find_restore_payload "$backup_dir" || true)"
  [[ -n "$payload" ]] || log_fatal "no supported dump payload found under $backup_dir"

  format="${payload%%|*}"
  restore_file="${payload#*|}"
  filestore_dir="$backup_dir/filestore"
  target_filestore="$DATA_DIR/filestore/$DB_NAME"

  # Register rollback action before destructive operations
  if declare -f rollback_register >/dev/null 2>&1; then
    rollback_register "restore_database" "log_warn 'manual cleanup may be needed for database $DB_NAME'"
  fi

  case "$RESTORE_STRATEGY" in
    refresh)
      restore_with_refresh_strategy "$format" "$restore_file"
      ;;
    reuse)
      if db_exists; then
        log_info "database already exists and RESTORE_STRATEGY=reuse; skipping database restore"
        return 0
      fi
      create_database_if_needed
      restore_payload_into_database "$format" "$restore_file" "$DB_NAME"
      ;;
    fail)
      if db_exists; then
        log_fatal "database $DB_NAME already exists and RESTORE_STRATEGY=fail"
      fi
      create_database_if_needed
      restore_payload_into_database "$format" "$restore_file" "$DB_NAME"
      ;;
  esac

  # Sync filestore if present in backup
  if [[ -d "$filestore_dir" ]] && [[ -n "$(find "$filestore_dir" -mindepth 1 -maxdepth 1 2>/dev/null | head -n 1)" ]]; then
    log_info "syncing filestore into $target_filestore"
    mirror_filestore "$filestore_dir" "$target_filestore"
  else
    log_info "backup has no filestore content; restore completed without attachments"
  fi

  # Run post-restore hooks if available
  if declare -f run_post_restore_hooks >/dev/null 2>&1; then
    run_post_restore_hooks
  fi

  # Auto-cleanup extracted backup directory to reclaim disk space
  if [[ -d "$backup_dir" && "$backup_dir" == "$RESTORE_WORKDIR/"* ]]; then
    log_info "cleaning up extracted backup directory to save space: $backup_dir"
    rm -rf "$backup_dir"
  fi
}
