#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="${ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}"
CMD="${1:-help}"
if [[ $# -gt 0 ]]; then
  shift
fi

DOWNLOAD_DIR="${DOWNLOAD_DIR:-$ROOT/.downloads/drive-folder}"
EXTRACT_ROOT="${EXTRACT_ROOT:-$ROOT}"
LOG_FILE="${LOG_FILE:-$ROOT/.logs/drive-folder-download.log}"
PID_FILE="${PID_FILE:-$ROOT/.run/drive-folder-download.pid}"
VENV_DIR="${VENV_DIR:-$ROOT/.venv-drive-fetch}"
SESSION_NAME="${SESSION_NAME:-drive_fetch_gdrive}"
EXTRACT_MODE="${EXTRACT_MODE:-smart}"

log() {
  printf '[%s] [drive-fetch] %s\n' "$(date '+%Y-%m-%dT%H:%M:%S%z')" "$*" >&2
}

usage() {
  cat <<'EOF'
Usage:
  ./download_drive_folder.sh start <google_drive_folder_url>
  ./download_drive_folder.sh run <google_drive_folder_url>
  ./download_drive_folder.sh status
  ./download_drive_folder.sh logs
  ./download_drive_folder.sh stop
  ./download_drive_folder.sh help

Behavior:
  start   Run download + materialize + extraction in background.
  run     Run download + extraction in the current shell.
  status  Show background PID/log/paths.
  logs    Follow the background log file.
  stop    Stop the background download process.

Environment:
  DOWNLOAD_DIR  Staging directory where Google Drive files are downloaded.
  EXTRACT_ROOT  Directory where downloaded archives are extracted.
  EXTRACT_MODE  smart | all | skip (default: smart).
  VENV_DIR      Virtualenv used for gdown when gdown is not installed globally.
EOF
}

ensure_dirs() {
  mkdir -p "$DOWNLOAD_DIR" "$EXTRACT_ROOT" "$ROOT/.logs" "$ROOT/.run"
}

read_pid_file() {
  local file="$1"
  if [[ -f "$file" ]]; then
    cat "$file"
  fi
}

pid_is_running() {
  local pid="$1"
  [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null
}

archive_stem() {
  local archive="$1"
  local name
  name="$(basename "$archive")"

  case "$name" in
    *.tar.gz)
      printf '%s\n' "${name%.tar.gz}"
      ;;
    *.tgz)
      printf '%s\n' "${name%.tgz}"
      ;;
    *.zip)
      printf '%s\n' "${name%.zip}"
      ;;
    *)
      printf '%s\n' "$name"
      ;;
  esac
}

extract_zip_archive() {
  local archive="$1"
  local destination="$2"

  if command -v unzip >/dev/null 2>&1; then
    unzip -oq "$archive" -d "$destination"
    return 0
  fi

  command -v python3 >/dev/null 2>&1 || {
    log "python3 is required to extract zip archives when unzip is unavailable"
    return 1
  }

  python3 - "$archive" "$destination" <<'PY'
import sys
import zipfile

with zipfile.ZipFile(sys.argv[1]) as archive:
    archive.extractall(sys.argv[2])
PY
}

extract_tar_archive() {
  local archive="$1"
  local destination="$2"
  tar -xzf "$archive" -C "$destination"
}

zip_list_entries() {
  local archive="$1"

  if command -v unzip >/dev/null 2>&1; then
    unzip -Z1 "$archive"
    return 0
  fi

  command -v python3 >/dev/null 2>&1 || {
    log "python3 is required to inspect zip archives when unzip is unavailable"
    return 1
  }

  python3 - "$archive" <<'PY'
import sys
import zipfile

with zipfile.ZipFile(sys.argv[1]) as archive:
    for name in archive.namelist():
        print(name)
PY
}

should_extract_archive() {
  local archive="$1"
  local entries

  case "$EXTRACT_MODE" in
    skip)
      return 1
      ;;
    all)
      return 0
      ;;
    smart)
      case "$archive" in
        *.zip)
          entries="$(zip_list_entries "$archive" 2>/dev/null || true)"
          [[ -n "$entries" ]] || return 1

          if grep -Eq '(^|/)dump\.sql$|(^|/).+\.(dump|backup)$|(^|/)filestore/' <<<"$entries"; then
            return 1
          fi

          grep -Eq '(^|/)__manifest__\.py$' <<<"$entries"
          return $?
          ;;
        *.tar.gz|*.tgz)
          return 1
          ;;
        *)
          return 1
          ;;
      esac
      ;;
    *)
      log "unsupported EXTRACT_MODE=$EXTRACT_MODE, defaulting to skip"
      return 1
      ;;
  esac
}

materialize_downloads_into_root() {
  local file relative_path destination

  while IFS= read -r -d '' file; do
    relative_path="${file#$DOWNLOAD_DIR/}"
    destination="$ROOT/$relative_path"
    mkdir -p "$(dirname "$destination")"

    if [[ -e "$destination" ]]; then
      if [[ "$file" -ef "$destination" ]]; then
        log "reusing root-level file: $destination"
        continue
      fi
      rm -f "$destination"
    fi

    if ln "$file" "$destination" 2>/dev/null; then
      log "linked downloaded file into root: $destination"
    else
      cp -f "$file" "$destination"
      log "copied downloaded file into root: $destination"
    fi
  done < <(find "$DOWNLOAD_DIR" -type f ! -name '*.part' ! -name '*.part.*' -print0)
}

extract_downloads() {
  local archive relative_dir destination marker

  while IFS= read -r -d '' archive; do
    if ! should_extract_archive "$archive"; then
      log "skipping archive extraction: $archive"
      continue
    fi

    relative_dir="$(dirname "${archive#$DOWNLOAD_DIR/}")"
    if [[ "$relative_dir" == "." ]]; then
      relative_dir=""
    fi

    destination="$EXTRACT_ROOT"
    if [[ -n "$relative_dir" ]]; then
      destination="$destination/$relative_dir"
    fi
    destination="$destination/$(archive_stem "$archive")"
    marker="$destination/.extracted.ok"

    if [[ -f "$marker" && "$marker" -nt "$archive" ]]; then
      log "reusing extracted archive at $destination"
      continue
    fi

    rm -rf "$destination"
    mkdir -p "$destination"

    case "$archive" in
      *.zip)
        log "extracting zip archive: $archive"
        extract_zip_archive "$archive" "$destination"
        ;;
      *.tar.gz|*.tgz)
        log "extracting tar archive: $archive"
        extract_tar_archive "$archive" "$destination"
        ;;
      *)
        continue
        ;;
    esac

    touch "$marker"
  done < <(find "$DOWNLOAD_DIR" -type f \( -name '*.zip' -o -name '*.tar.gz' -o -name '*.tgz' \) -print0)
}

resolve_gdown_command() {
  if command -v gdown >/dev/null 2>&1; then
    printf '%s\n' "gdown"
    return 0
  fi

  if [[ -x "$VENV_DIR/bin/gdown" ]]; then
    printf '%s\n' "$VENV_DIR/bin/gdown"
    return 0
  fi

  command -v python3 >/dev/null 2>&1 || {
    log "python3 is required to install gdown"
    return 1
  }

  log "installing gdown into $VENV_DIR"
  python3 -m venv "$VENV_DIR"
  "$VENV_DIR/bin/pip" install --upgrade pip >/dev/null
  "$VENV_DIR/bin/pip" install gdown >/dev/null
  printf '%s\n' "$VENV_DIR/bin/gdown"
}

screen_session_exists() {
  command -v screen >/dev/null 2>&1 || return 1
  screen -ls 2>/dev/null | grep -Eq "[[:digit:]]+\\.${SESSION_NAME}[[:space:]]"
}

run_download() {
  local url="${1:?google drive folder url is required}"
  local gdown_bin

  ensure_dirs
  gdown_bin="$(resolve_gdown_command)"

  log "downloading Google Drive folder into $DOWNLOAD_DIR"
  "$gdown_bin" --folder --remaining-ok "$url" -O "$DOWNLOAD_DIR"
  log "download complete; materializing files into $ROOT"
  materialize_downloads_into_root
  log "materialization complete; starting archive extraction into $EXTRACT_ROOT"
  extract_downloads
  log "download + extraction complete"
}

start_background() {
  local url="${1:?google drive folder url is required}"
  local pid shell_command

  ensure_dirs

  if screen_session_exists; then
    log "download already running in screen session $SESSION_NAME"
    return 0
  fi

  pid="$(read_pid_file "$PID_FILE")"
  if pid_is_running "$pid"; then
    log "download already running with pid $pid"
    return 0
  fi

  if command -v screen >/dev/null 2>&1; then
    printf -v shell_command 'cd %q && ROOT=%q DOWNLOAD_DIR=%q EXTRACT_ROOT=%q LOG_FILE=%q PID_FILE=%q VENV_DIR=%q SESSION_NAME=%q bash %q run %q >> %q 2>&1' \
      "$ROOT" "$ROOT" "$DOWNLOAD_DIR" "$EXTRACT_ROOT" "$LOG_FILE" "$PID_FILE" "$VENV_DIR" "$SESSION_NAME" "$ROOT/download_drive_folder.sh" "$url" "$LOG_FILE"
    screen -dmS "$SESSION_NAME" bash -lc "$shell_command"
    printf 'screen:%s\n' "$SESSION_NAME" >"$PID_FILE"
    log "started background download in screen session $SESSION_NAME"
    log "log file: $LOG_FILE"
    return 0
  fi

  nohup env \
    ROOT="$ROOT" \
    DOWNLOAD_DIR="$DOWNLOAD_DIR" \
    EXTRACT_ROOT="$EXTRACT_ROOT" \
    LOG_FILE="$LOG_FILE" \
    PID_FILE="$PID_FILE" \
    VENV_DIR="$VENV_DIR" \
    SESSION_NAME="$SESSION_NAME" \
    bash "$ROOT/download_drive_folder.sh" run "$url" </dev/null >>"$LOG_FILE" 2>&1 &
  echo "$!" >"$PID_FILE"
  log "started background download pid=$!"
  log "log file: $LOG_FILE"
}

show_status() {
  local pid
  pid="$(read_pid_file "$PID_FILE")"

  if screen_session_exists; then
    log "background download running in screen session $SESSION_NAME"
    log "download dir: $DOWNLOAD_DIR"
    log "extract dir: $EXTRACT_ROOT"
    log "log file: $LOG_FILE"
    return 0
  fi

  if pid_is_running "$pid"; then
    log "background download running with pid $pid"
  else
    log "background download not running"
  fi

  log "download dir: $DOWNLOAD_DIR"
  log "extract dir: $EXTRACT_ROOT"
  log "log file: $LOG_FILE"
}

show_logs() {
  ensure_dirs
  touch "$LOG_FILE"
  tail -f "$LOG_FILE"
}

stop_background() {
  local pid
  if screen_session_exists; then
    log "stopping background download screen session $SESSION_NAME"
    screen -S "$SESSION_NAME" -X quit >/dev/null 2>&1 || true
  fi

  pid="$(read_pid_file "$PID_FILE")"
  if [[ "$pid" != screen:* ]] && pid_is_running "$pid"; then
    log "stopping background download pid $pid"
    kill "$pid" 2>/dev/null || true
  fi
  rm -f "$PID_FILE"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  case "$CMD" in
    start)
      start_background "$@"
      ;;
    run)
      run_download "$@"
      ;;
    status)
      show_status
      ;;
    logs)
      show_logs
      ;;
    stop)
      stop_background
      ;;
    help|-h|--help)
      usage
      ;;
    *)
      usage >&2
      exit 1
      ;;
  esac
fi
