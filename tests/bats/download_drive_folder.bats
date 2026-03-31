#!/usr/bin/env bats
# ============================================================================
# download_drive_folder.bats — Unit tests for download_drive_folder.sh
# ============================================================================

load test_helper

setup() {
  setup_test_environment
  export DOWNLOAD_DIR="$ROOT/downloads"
  export EXTRACT_ROOT="$ROOT"
  export LOG_FILE="$ROOT/.logs/drive-folder-download.log"
  export PID_FILE="$ROOT/.run/drive-folder-download.pid"
  export VENV_DIR="$ROOT/.venv-drive-fetch"
  export SESSION_NAME="drive_fetch_test"
  export EXTRACT_MODE="smart"
  # shellcheck source=/dev/null
  source "$PROJECT_ROOT/download_drive_folder.sh"
}

teardown() {
  teardown_test_environment
}

@test "archive_stem strips supported archive suffixes" {
  [ "$(archive_stem "/tmp/sample.zip")" = "sample" ]
  [ "$(archive_stem "/tmp/sample.tar.gz")" = "sample" ]
  [ "$(archive_stem "/tmp/sample.tgz")" = "sample" ]
}

@test "extract_downloads in smart mode extracts addons zip but skips backup and tarball" {
  mkdir -p "$DOWNLOAD_DIR" "$ROOT/tar-src"

  python3 - <<PY
import pathlib
import zipfile

downloads = pathlib.Path(r"$DOWNLOAD_DIR")
with zipfile.ZipFile(downloads / "addons_bundle.zip", "w") as archive:
    archive.writestr("addons/module/__manifest__.py", "{}\n")
with zipfile.ZipFile(downloads / "db_backup.zip", "w") as archive:
    archive.writestr("dump.sql", "-- dump\n")
    archive.writestr("filestore/.keep", "")
PY

  printf 'hello\n' >"$ROOT/tar-src/file.txt"
  tar -czf "$DOWNLOAD_DIR/odoo_source.tar.gz" -C "$ROOT/tar-src" .

  extract_downloads

  [ -f "$ROOT/addons_bundle/addons/module/__manifest__.py" ]
  [ ! -d "$ROOT/db_backup" ]
  [ ! -d "$ROOT/odoo_source" ]
}

@test "materialize_downloads_into_root refreshes stale root artifacts" {
  mkdir -p "$DOWNLOAD_DIR/subdir"
  printf 'new-payload\n' >"$DOWNLOAD_DIR/subdir/archive.zip"
  mkdir -p "$ROOT/subdir"
  printf 'old-payload\n' >"$ROOT/subdir/archive.zip"

  materialize_downloads_into_root

  [ -f "$ROOT/subdir/archive.zip" ]
  grep -q 'new-payload' "$ROOT/subdir/archive.zip"
}

@test "should_extract_archive skips backup zip in smart mode" {
  python3 - <<PY
import pathlib
import zipfile

downloads = pathlib.Path(r"$DOWNLOAD_DIR")
downloads.mkdir(parents=True, exist_ok=True)
with zipfile.ZipFile(downloads / "db_backup.zip", "w") as archive:
    archive.writestr("dump.sql", "-- dump\n")
PY

  run should_extract_archive "$DOWNLOAD_DIR/db_backup.zip"

  [ "$status" -ne 0 ]
}
