#!/usr/bin/env bash
# ============================================================================
# platform.sh — Platform detection, resource measurement, and prerequisites
# ============================================================================
# Detects OS family, Linux distro, available RAM, CPU count, and free disk
# space. Results are cached to avoid repeated system calls.
# ============================================================================

[[ -n "${_PLATFORM_SH_LOADED:-}" ]] && return 0
_PLATFORM_SH_LOADED=1

# Cache variables for expensive system calls
_MEMORY_GB_CACHE=""
_CPU_COUNT_CACHE=""

# Require a command to be available, or exit with an error.
# Arguments: $1=command name
require_cmd() {
  command -v "$1" >/dev/null 2>&1 || log_fatal "required command not found: $1"
}

# Return success when the current shell runs as root.
is_root_user() {
  [[ "$(id -u)" == "0" ]]
}

# Return success when the current shell still has a usable terminal attached.
shell_has_tty() {
  [[ -t 0 || -t 1 || -t 2 ]]
}

# Return success when sudo can run without prompting for a password.
sudo_can_run_noninteractive() {
  if is_root_user; then
    return 0
  fi

  require_cmd sudo
  sudo -n true >/dev/null 2>&1
}

# Run a command with root privileges.
# Uses sudo only when the current shell is not already root.
run_privileged() {
  if is_root_user; then
    "$@"
    return $?
  fi

  require_cmd sudo

  if shell_has_tty; then
    sudo "$@"
    return $?
  fi

  if sudo_can_run_noninteractive; then
    sudo -n "$@"
    return $?
  else
    log_fatal "command requires sudo but no terminal is available — run in an interactive shell, configure passwordless sudo, or preinstall the required dependency"
  fi
}

# Fail fast when detached bootstrap would require an interactive sudo prompt.
require_noninteractive_sudo_for_background() {
  if is_root_user; then
    return 0
  fi

  sudo_can_run_noninteractive || log_fatal "background bootstrap cannot prompt for sudo password — run as root, configure passwordless sudo, or use './setup_odoo.sh bootstrap' in an interactive shell"
}

# List archive entries from a zip file.
# Prefers unzip for speed, but falls back to python3 when unavailable.
# Arguments: $1=zip archive path
zip_list_entries() {
  local archive="$1"

  if command -v unzip >/dev/null 2>&1; then
    unzip -Z1 "$archive"
    return 0
  fi

  if command -v python3 >/dev/null 2>&1; then
    python3 - "$archive" <<'PY'
import sys
import zipfile

with zipfile.ZipFile(sys.argv[1]) as archive:
    for name in archive.namelist():
        print(name)
PY
    return 0
  fi

  log_fatal "required command not found: unzip or python3"
}

# Extract a zip archive into the target directory.
# Prefers unzip for speed, but falls back to python3 when unavailable.
# Arguments: $1=zip archive path, $2=destination directory
extract_zip_archive() {
  local archive="$1"
  local destination="$2"

  if command -v unzip >/dev/null 2>&1; then
    unzip -oq "$archive" -d "$destination"
    return 0
  fi

  if command -v python3 >/dev/null 2>&1; then
    python3 - "$archive" "$destination" <<'PY'
import sys
import zipfile

with zipfile.ZipFile(sys.argv[1]) as archive:
    archive.extractall(sys.argv[2])
PY
    return 0
  fi

  log_fatal "required command not found: unzip or python3"
}

# Detect operating system family and Linux distro.
# Sets globals: OS_FAMILY (linux|macos|windows), LINUX_DISTRO (ubuntu|debian|...)
detect_platform() {
  local uname_s
  uname_s="$(uname -s)"
  case "$uname_s" in
    Linux)
      OS_FAMILY="linux"
      if [[ -f /etc/os-release ]]; then
        # shellcheck disable=SC1091
        source /etc/os-release
        LINUX_DISTRO="${ID:-linux}"
      else
        LINUX_DISTRO="linux"
      fi
      ;;
    Darwin)
      OS_FAMILY="macos"
      ;;
    MINGW*|MSYS*|CYGWIN*)
      OS_FAMILY="windows"
      ;;
    *)
      log_fatal "unsupported platform: $uname_s"
      ;;
  esac
  log_debug "detected platform: OS_FAMILY=$OS_FAMILY LINUX_DISTRO=${LINUX_DISTRO:-n/a}"
}

# Detect total system memory in gigabytes. Result is cached after first call.
# Output: integer GB on stdout
detect_memory_gb() {
  if [[ -n "$_MEMORY_GB_CACHE" ]]; then
    printf '%s\n' "$_MEMORY_GB_CACHE"
    return 0
  fi

  if [[ "$OS_FAMILY" == "linux" ]] && [[ -r /proc/meminfo ]]; then
    _MEMORY_GB_CACHE="$(( $(awk '/MemTotal/ {print $2}' /proc/meminfo) / 1024 / 1024 ))"
  elif [[ "$OS_FAMILY" == "macos" ]] && command -v sysctl >/dev/null 2>&1; then
    _MEMORY_GB_CACHE="$(( $(sysctl -n hw.memsize 2>/dev/null || echo 0) / 1024 / 1024 / 1024 ))"
  else
    _MEMORY_GB_CACHE="0"
  fi

  printf '%s\n' "$_MEMORY_GB_CACHE"
}

# Detect the number of logical CPUs. Result is cached after first call.
# Output: integer CPU count on stdout
detect_cpu_count() {
  if [[ -n "$_CPU_COUNT_CACHE" ]]; then
    printf '%s\n' "$_CPU_COUNT_CACHE"
    return 0
  fi

  if command -v getconf >/dev/null 2>&1; then
    _CPU_COUNT_CACHE="$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 1)"
  elif [[ "$OS_FAMILY" == "macos" ]] && command -v sysctl >/dev/null 2>&1; then
    _CPU_COUNT_CACHE="$(sysctl -n hw.logicalcpu 2>/dev/null || echo 1)"
  else
    _CPU_COUNT_CACHE="1"
  fi

  [[ "$_CPU_COUNT_CACHE" =~ ^[0-9]+$ ]] || _CPU_COUNT_CACHE="1"
  printf '%s\n' "$_CPU_COUNT_CACHE"
}

# Check that available disk space meets the MIN_FREE_GB threshold.
# Dies if insufficient space is detected.
check_free_space() {
  local available_kb available_gb
  if command -v df >/dev/null 2>&1; then
    available_kb="$(df -Pk "$ROOT" | awk 'NR==2 {print $4}')"
    if [[ "$available_kb" =~ ^[0-9]+$ ]]; then
      available_gb=$((available_kb / 1024 / 1024))
      log_info "free disk space: ${available_gb}G"
      if (( available_gb < MIN_FREE_GB )); then
        log_fatal "free disk space ${available_gb}G is below MIN_FREE_GB=${MIN_FREE_GB}G"
      fi
    fi
  fi
}

# Log a warning if system RAM is below the recommended 4GB threshold.
check_memory_hint() {
  local mem_gb
  mem_gb="$(detect_memory_gb)"
  if [[ "$mem_gb" =~ ^[0-9]+$ ]] && (( mem_gb > 0 )); then
    log_info "detected RAM: ${mem_gb}G"
    if (( mem_gb < 4 )); then
      log_warn "less than 4G RAM detected; multi-worker Odoo may be unstable"
    fi
  fi
}

# Find the first file matching a glob pattern in ROOT directory.
# Arguments: $1=glob pattern
# Output: full path on stdout (empty if not found)
pick_file() {
  local pattern="$1"
  find "$ROOT" -maxdepth 1 -type f -name "$pattern" | sort | head -n 1 || true
}
