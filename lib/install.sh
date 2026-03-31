#!/usr/bin/env bash
# ============================================================================
# install.sh — Odoo installation from various artifact types
# ============================================================================
# Supports: source (tar.gz), .deb package, .exe package, existing source dir.
# Handles Python virtualenv setup, package extraction, and install mode
# auto-detection.
#
# Configurable via:
#   INSTALL_MODE            — auto|source|deb|exe
#   CUSTOM_ADDONS_ZIP_PATTERNS — glob patterns for addons zip (pipe-separated)
#   ODOO_PACKAGE_SHA256     — optional SHA256 checksum for package verification
# ============================================================================

[[ -n "${_INSTALL_SH_LOADED:-}" ]] && return 0
_INSTALL_SH_LOADED=1

# Configurable glob patterns for custom addons zip files.
# Pipe-separated list of patterns to match against filenames.
CUSTOM_ADDONS_ZIP_PATTERNS="${CUSTOM_ADDONS_ZIP_PATTERNS:-*addons*.zip}"

# System packages required on Ubuntu/Debian for building Odoo from source.
APT_PACKAGES=(
  build-essential
  curl
  fonts-dejavu-core
  git
  libffi-dev
  libjpeg-dev
  libldap2-dev
  libpq-dev
  libsasl2-dev
  libssl-dev
  libxml2-dev
  libxslt1-dev
  pkg-config
  postgresql
  postgresql-contrib
  python3
  python3-dev
  python3-pip
  python3-venv
  rsync
  unzip
  wkhtmltopdf
  zlib1g-dev
)

# Verify package checksum if ODOO_PACKAGE_SHA256 is set.
# Arguments: $1=file path
_verify_package_checksum() {
  local file="$1"
  if [[ -z "${ODOO_PACKAGE_SHA256:-}" ]]; then
    log_debug "no ODOO_PACKAGE_SHA256 set, skipping checksum verification"
    return 0
  fi

  local actual_sha256
  if command -v sha256sum >/dev/null 2>&1; then
    actual_sha256="$(sha256sum "$file" | awk '{print $1}')"
  elif command -v shasum >/dev/null 2>&1; then
    actual_sha256="$(shasum -a 256 "$file" | awk '{print $1}')"
  else
    log_warn "no sha256sum or shasum available, skipping checksum verification"
    return 0
  fi

  if [[ "$actual_sha256" != "$ODOO_PACKAGE_SHA256" ]]; then
    log_fatal "checksum mismatch for $file: expected=$ODOO_PACKAGE_SHA256, actual=$actual_sha256"
  fi
  log_info "checksum verified for $file"
}

# Auto-detect the best installation mode based on available artifacts and OS.
# Output: install mode string (source|deb|exe) on stdout
resolve_install_mode() {
  local tar_candidate deb_candidate exe_candidate
  [[ "$INSTALL_MODE" != "auto" ]] && {
    printf '%s\n' "$INSTALL_MODE"
    return 0
  }

  tar_candidate="${ODOO_TAR_GZ:-$(pick_file 'odoo*.tar.gz')}"
  deb_candidate="${ODOO_DEB_PACKAGE:-$(pick_file 'odoo*.deb')}"
  exe_candidate="${ODOO_EXE_PACKAGE:-$(pick_file 'odoo*.exe')}"

  if [[ "$OS_FAMILY" == "windows" && -n "$exe_candidate" ]]; then
    ODOO_EXE_PACKAGE="$exe_candidate"
    printf '%s\n' "exe"
    return 0
  fi

  if [[ "$OS_FAMILY" == "linux" && ( "$LINUX_DISTRO" == "ubuntu" || "$LINUX_DISTRO" == "debian" ) && -n "$deb_candidate" ]]; then
    ODOO_DEB_PACKAGE="$deb_candidate"
    printf '%s\n' "deb"
    return 0
  fi

  if [[ -n "$tar_candidate" ]]; then
    ODOO_TAR_GZ="$tar_candidate"
    printf '%s\n' "source"
    return 0
  fi

  if [[ -n "$deb_candidate" ]]; then
    ODOO_DEB_PACKAGE="$deb_candidate"
    printf '%s\n' "deb"
    return 0
  fi

  if [[ -n "$exe_candidate" ]]; then
    ODOO_EXE_PACKAGE="$exe_candidate"
    printf '%s\n' "exe"
    return 0
  fi

  log_fatal "unable to detect Odoo installer/source artifact"
}

# Detect an existing Odoo source directory (extracted previously).
# Output: source directory path on stdout (empty if not found)
detect_odoo_src_from_existing() {
  local candidate
  [[ -n "$ODOO_SRC_DIR" ]] && {
    printf '%s\n' "$ODOO_SRC_DIR"
    return 0
  }

  candidate="$(find "$ROOT" -maxdepth 2 -type f -path '*/setup/odoo' | sort | head -n 1 || true)"
  [[ -n "$candidate" ]] && dirname "$(dirname "$candidate")"
}

# Extract the Odoo tar.gz archive to the artifacts directory.
# Skips extraction if a marker file indicates it was already done.
extract_odoo_tarball() {
  local extract_dir
  require_cmd tar
  ODOO_TAR_GZ="${ODOO_TAR_GZ:-$(pick_file 'odoo*.tar.gz')}"
  [[ -n "$ODOO_TAR_GZ" ]] || log_fatal "odoo tar.gz not found"

  _verify_package_checksum "$ODOO_TAR_GZ"

  extract_dir="$ARTIFACTS_DIR/$(basename "${ODOO_TAR_GZ%.tar.gz}")"
  if [[ ! -f "$extract_dir/.extracted.ok" ]]; then
    rm -rf "$extract_dir"
    mkdir -p "$extract_dir"
    log_info "extracting Odoo tar.gz to $extract_dir"
    tar -xzf "$ODOO_TAR_GZ" -C "$extract_dir" --strip-components=1
    touch "$extract_dir/.extracted.ok"
  else
    log_debug "reusing previously extracted Odoo source at $extract_dir"
  fi
  ODOO_SRC_DIR="$extract_dir"
}

# Detect the custom addons directory by scanning for __manifest__.py files.
# First checks for existing directories, then tries to extract from zip files.
# Uses CUSTOM_ADDONS_ZIP_PATTERNS for matching zip file names.
# Output: addons directory path on stdout
detect_custom_addons() {
  local best_dir best_count count dir candidate extract_dir
  [[ -n "$CUSTOM_ADDONS_DIR" ]] && {
    [[ -d "$CUSTOM_ADDONS_DIR" ]] || log_fatal "CUSTOM_ADDONS_DIR does not exist: $CUSTOM_ADDONS_DIR"
    printf '%s\n' "$CUSTOM_ADDONS_DIR"
    return 0
  }

  # Scan top-level directories for existing addons
  best_dir=""
  best_count=0
  while IFS= read -r dir; do
    count="$(find "$dir" -maxdepth 2 -name '__manifest__.py' | wc -l | tr -d ' ')"
    if [[ "$count" =~ ^[0-9]+$ ]] && (( count > best_count )); then
      best_count="$count"
      best_dir="$dir"
    fi
  done < <(find "$ROOT" -mindepth 1 -maxdepth 1 -type d ! -name '.venv' ! -name '.local' ! -name '.restore' ! -name '.artifacts' ! -name '.logs' ! -name '.run' ! -name '.rollback' | sort)

  # Try to find and extract a custom addons zip using configurable patterns
  local IFS='|'
  local patterns_array
  read -ra patterns_array <<< "$CUSTOM_ADDONS_ZIP_PATTERNS"

  for pattern in "${patterns_array[@]}"; do
    candidate="$(pick_file "$pattern")"
    [[ -n "$candidate" ]] && break
  done

  # Fallback: sweep all remaining zip files and dynamically check contents
  if [[ -z "${candidate:-}" ]]; then
    while IFS= read -r zip_candidate; do
      if zip_list_entries "$zip_candidate" 2>/dev/null | grep -Eq '(^|/)__manifest__\.py$'; then
        candidate="$zip_candidate"
        break
      fi
    done < <(find "$ROOT" -maxdepth 2 \
      \( -path "$RESTORE_WORKDIR" -o -path "$ARTIFACTS_DIR" -o -path "$ROOT/.logs" -o -path "$ROOT/.run" -o -path "$ROOT/.rollback" -o -path "$ROOT/.local" -o -path "$ROOT/.venv" -o -path "$ROOT/.git" \) -prune -o \
      -type f -name '*.zip' -print | sort)
  fi

  if [[ -n "${candidate:-}" ]]; then
    extract_dir="$ARTIFACTS_DIR/$(basename "${candidate%.zip}")"
    if [[ ! -f "$extract_dir/.extracted.ok" ]]; then
      rm -rf "$extract_dir"
      mkdir -p "$extract_dir"
      log_info "extracting custom addons zip to $extract_dir"
      extract_zip_archive "$candidate" "$extract_dir"
      touch "$extract_dir/.extracted.ok"
    fi

    best_dir="$(find "$extract_dir" -mindepth 1 -maxdepth 2 -type d | while IFS= read -r dir; do
      count="$(find "$dir" -maxdepth 2 -name '__manifest__.py' | wc -l | tr -d ' ')"
      if [[ "$count" =~ ^[0-9]+$ ]] && (( count > 0 )); then
        printf '%s|%s\n' "$count" "$dir"
      fi
    done | sort -t'|' -k1,1nr | head -n 1 | cut -d'|' -f2- || true)"
  fi

  [[ -n "$best_dir" ]] || log_fatal "unable to detect custom addons directory"
  printf '%s\n' "$best_dir"
}

# Install system packages on Ubuntu/Debian if needed for source builds.
install_linux_packages_if_needed() {
  [[ "$OS_FAMILY" == "linux" ]] || return 0
  [[ "$INSTALL_MODE" == "source" || "$INSTALL_MODE" == "deb" ]] || return 0

  if [[ "$LINUX_DISTRO" == "ubuntu" || "$LINUX_DISTRO" == "debian" ]]; then
    require_cmd apt-get
    log_info "installing system packages for $LINUX_DISTRO"
    run_privileged apt-get update
    run_privileged env DEBIAN_FRONTEND=noninteractive apt-get install -y "${APT_PACKAGES[@]}"
  else
    log_info "skipping auto package install on non-Ubuntu Linux"
  fi
}

# Return success when the target Python runtime can import lxml.html.clean.
# Arguments: $1=python executable
python_has_lxml_html_clean() {
  local python_bin="$1"
  [[ -n "$python_bin" ]] || return 1

  "$python_bin" - <<'PY' >/dev/null 2>&1
from lxml.html import clean  # noqa: F401
PY
}

# Retry a dependency repair command to tolerate transient apt/pip failures.
# Arguments: $1=label, $2...=command
dependency_repair_with_retries() {
  local label="$1"
  shift

  local retries="${ODOO_DEPENDENCY_REPAIR_RETRIES:-3}"
  local retry_delay="${ODOO_DEPENDENCY_REPAIR_RETRY_DELAY:-5}"
  local attempt=1
  [[ "$retries" =~ ^[0-9]+$ ]] && (( retries >= 1 )) || retries=3
  [[ "$retry_delay" =~ ^[0-9]+$ ]] && (( retry_delay >= 1 )) || retry_delay=5

  while (( attempt <= retries )); do
    if "$@"; then
      return 0
    fi

    if (( attempt == retries )); then
      log_error "$label failed after $retries attempts"
      return 1
    fi

    log_warn "$label attempt $attempt/$retries failed, retrying in ${retry_delay}s..."
    sleep "$retry_delay"
    (( attempt++ ))
  done
}

# Fail fast in unattended shells when a privileged repair would hang on sudo.
ensure_privileged_dependency_repair_supported() {
  if is_root_user; then
    return 0
  fi

  if [[ -t 0 && -t 2 ]]; then
    return 0
  fi

  require_cmd sudo
  sudo -n true >/dev/null 2>&1 || log_fatal "runtime dependency auto-repair cannot prompt for sudo in non-interactive mode — run as root, configure passwordless sudo, set ODOO_RUNTIME_AUTO_REPAIR=0, or install the dependency manually"
}

# Return success when python -m pip is available.
# Arguments: $1=python executable
python_has_pip() {
  local python_bin="$1"
  "$python_bin" -m pip --version >/dev/null 2>&1
}

# Return success when python can bootstrap pip via ensurepip.
# Arguments: $1=python executable
python_supports_ensurepip() {
  local python_bin="$1"
  "$python_bin" -m ensurepip --help >/dev/null 2>&1
}

# Return success when pip supports the externally-managed override flag.
# Arguments: $1=python executable
python_pip_supports_break_system_packages() {
  local python_bin="$1"
  "$python_bin" -m pip install --help 2>&1 | grep -Fq -- '--break-system-packages'
}

# Install a distro-managed Python package on Ubuntu/Debian with retries.
# Arguments: $1=package name
apt_install_python_package() {
  local package_name="$1"
  command -v apt-get >/dev/null 2>&1 || return 1

  ensure_privileged_dependency_repair_supported
  dependency_repair_with_retries \
    "apt-get install $package_name" \
    run_privileged env DEBIAN_FRONTEND=noninteractive apt-get install -y "$package_name"
}

# Ensure `python -m pip` exists before using pip-based runtime repairs.
# Arguments: $1=python executable, $2=venv|system
ensure_python_pip() {
  local python_bin="$1"
  local install_scope="${2:-venv}"

  if python_has_pip "$python_bin"; then
    return 0
  fi

  if [[ "$install_scope" == "system" && ( "$LINUX_DISTRO" == "ubuntu" || "$LINUX_DISTRO" == "debian" ) ]] && command -v apt-get >/dev/null 2>&1; then
    log_info "installing python3-pip for system Python"
    if apt_install_python_package "python3-pip" && python_has_pip "$python_bin"; then
      return 0
    fi
  fi

  if python_supports_ensurepip "$python_bin"; then
    log_info "bootstrapping pip via ensurepip for $install_scope python"
    if [[ "$install_scope" == "system" ]]; then
      ensure_privileged_dependency_repair_supported
      dependency_repair_with_retries \
        "python ensurepip for $python_bin" \
        run_privileged "$python_bin" -m ensurepip --upgrade
    else
      dependency_repair_with_retries \
        "python ensurepip for $python_bin" \
        "$python_bin" -m ensurepip --upgrade
    fi

    if python_has_pip "$python_bin"; then
      return 0
    fi
  fi

  log_fatal "python -m pip is unavailable for $install_scope python: $python_bin"
}

# Install Python packages via `python -m pip install`, optionally elevated.
# Arguments: $1=0|1 privileged, $2=python executable, $@=packages/flags
run_python_pip_install() {
  local use_privileged="$1"
  local python_bin="$2"
  shift 2

  local install_scope="venv"
  local pip_args=(-m pip install)
  if [[ "$use_privileged" == "1" ]]; then
    install_scope="system"
  fi

  ensure_python_pip "$python_bin" "$install_scope"

  if python_pip_supports_break_system_packages "$python_bin"; then
    pip_args+=(--break-system-packages)
  fi

  if [[ "$use_privileged" == "1" ]]; then
    ensure_privileged_dependency_repair_supported
    dependency_repair_with_retries \
      "pip install $*" \
      run_privileged env PIP_DISABLE_PIP_VERSION_CHECK=1 PIP_ROOT_USER_ACTION=ignore "$python_bin" "${pip_args[@]}" "$@"
  else
    dependency_repair_with_retries \
      "pip install $*" \
      env PIP_DISABLE_PIP_VERSION_CHECK=1 PIP_ROOT_USER_ACTION=ignore "$python_bin" "${pip_args[@]}" "$@"
  fi
}

# Resolve a Python interpreter from an executable script shebang.
# Supports direct paths and `/usr/bin/env python3` style shebangs.
# Arguments: $1=script path or command name
# Output: python executable path on stdout
resolve_python_bin_from_shebang() {
  local target="$1"
  local first_line interpreter
  local -a shebang_parts=()

  [[ -n "$target" ]] || return 1
  if [[ ! -e "$target" ]]; then
    target="$(command -v "$target" 2>/dev/null || true)"
  fi
  [[ -r "$target" ]] || return 1

  IFS= read -r first_line < "$target" || true
  [[ "$first_line" == '#!'* ]] || return 1
  first_line="${first_line#\#!}"
  read -r -a shebang_parts <<< "$first_line"
  (( ${#shebang_parts[@]} > 0 )) || return 1

  if [[ "$(basename "${shebang_parts[0]}")" == "env" ]]; then
    local idx=1
    if [[ "${shebang_parts[$idx]:-}" == "-S" ]]; then
      (( idx++ ))
    fi

    while (( idx < ${#shebang_parts[@]} )); do
      if [[ "${shebang_parts[$idx]}" == -* ]]; then
        (( idx++ ))
        continue
      fi

      interpreter="$(command -v "${shebang_parts[$idx]}" 2>/dev/null || true)"
      [[ -n "$interpreter" ]] || return 1
      printf '%s\n' "$interpreter"
      return 0
    done
    return 1
  fi

  interpreter="${shebang_parts[0]}"
  if [[ -x "$interpreter" ]]; then
    printf '%s\n' "$interpreter"
    return 0
  fi

  interpreter="$(command -v "$interpreter" 2>/dev/null || true)"
  [[ -n "$interpreter" ]] || return 1
  printf '%s\n' "$interpreter"
}

# Resolve the Python interpreter that will execute Odoo at runtime.
# Output: "<python_bin>|<venv|system>" on stdout
resolve_odoo_runtime_python() {
  local python_bin scope="system"

  if [[ -n "${ODOO_SRC_DIR:-}" ]]; then
    [[ -x "$VENV_DIR/bin/python" ]] || log_fatal "Odoo virtualenv Python not found: $VENV_DIR/bin/python"
    printf '%s|venv\n' "$VENV_DIR/bin/python"
    return 0
  fi

  if [[ -n "${ODOO_BIN:-}" ]]; then
    python_bin="$(resolve_python_bin_from_shebang "$ODOO_BIN" || true)"
    if [[ -z "$python_bin" ]] && command -v python3 >/dev/null 2>&1; then
      python_bin="$(command -v python3)"
    fi
    [[ -n "$python_bin" ]] || log_fatal "unable to resolve the Python interpreter for Odoo binary: $ODOO_BIN"

    if [[ -n "${VENV_DIR:-}" && "$python_bin" == "$VENV_DIR/"* ]]; then
      scope="venv"
    fi

    printf '%s|%s\n' "$python_bin" "$scope"
    return 0
  fi

  log_fatal "unable to resolve Odoo runtime Python — neither ODOO_SRC_DIR nor ODOO_BIN is set"
}

# Ensure the active Python runtime has the lxml html_clean extra available.
# For system Python, prefer distro packages first and fall back to pip.
# Arguments: $1=python executable, $2=venv|system
ensure_python_html_clean_dependency() {
  local python_bin="$1"
  local install_scope="${2:-venv}"

  if python_has_lxml_html_clean "$python_bin"; then
    log_debug "lxml.html.clean already available for $install_scope python: $python_bin"
    return 0
  fi

  if [[ "$install_scope" == "system" && ( "$LINUX_DISTRO" == "ubuntu" || "$LINUX_DISTRO" == "debian" ) ]] && command -v apt-get >/dev/null 2>&1; then
    log_info "installing python3-lxml-html-clean for system Python"
    if apt_install_python_package "python3-lxml-html-clean"; then
      if python_has_lxml_html_clean "$python_bin"; then
        return 0
      fi
      log_warn "python3-lxml-html-clean is installed but lxml.html.clean is still unavailable; falling back to pip"
    else
      log_warn "unable to install python3-lxml-html-clean via apt-get; falling back to pip"
    fi
  fi

  log_info "installing lxml_html_clean via pip for $install_scope python"
  if [[ "$install_scope" == "system" ]]; then
    run_python_pip_install 1 "$python_bin" lxml_html_clean
  else
    run_python_pip_install 0 "$python_bin" lxml_html_clean
  fi

  python_has_lxml_html_clean "$python_bin" || log_fatal "lxml.html.clean is unavailable for $install_scope python: $python_bin"
}

# Validate or repair the Python runtime dependencies needed before Odoo starts.
ensure_odoo_runtime_python_dependencies() {
  local runtime_info python_bin install_scope
  local auto_repair="${ODOO_RUNTIME_AUTO_REPAIR:-1}"

  runtime_info="$(resolve_odoo_runtime_python)"
  python_bin="${runtime_info%%|*}"
  install_scope="${runtime_info##*|}"

  if python_has_lxml_html_clean "$python_bin"; then
    log_debug "runtime dependency preflight passed for $python_bin"
    return 0
  fi

  if [[ "$auto_repair" != "1" ]]; then
    log_fatal "lxml.html.clean is unavailable for runtime python $python_bin; install python3-lxml-html-clean or lxml_html_clean manually, or re-run with ODOO_RUNTIME_AUTO_REPAIR=1"
  fi

  log_warn "runtime dependency preflight detected missing lxml.html.clean for $python_bin; attempting auto-repair"
  ensure_python_html_clean_dependency "$python_bin" "$install_scope"
}

# Set up the Python virtual environment and install Odoo dependencies.
# Uses a stamp file to skip reinstall if requirements haven't changed.
setup_python_env() {
  local requirements_file stamp_file new_stamp current_stamp
  require_cmd python3
  requirements_file="$ODOO_SRC_DIR/requirements.txt"
  stamp_file="$VENV_DIR/.requirements.stamp"
  [[ -f "$requirements_file" ]] || log_fatal "requirements.txt not found in $ODOO_SRC_DIR"

  new_stamp="$(cksum "$requirements_file"; printf '%s\n' "$ODOO_SRC_DIR")"
  current_stamp="$(cat "$stamp_file" 2>/dev/null || true)"

  if [[ -x "$VENV_DIR/bin/python" && "$current_stamp" == "$new_stamp" ]]; then
    log_info "reusing existing virtualenv at $VENV_DIR"
    ensure_python_html_clean_dependency "$VENV_DIR/bin/python" "venv"
    return 0
  fi

  log_info "creating virtualenv at $VENV_DIR"
  python3 -m venv "$VENV_DIR"
  "$VENV_DIR/bin/pip" install --upgrade pip wheel "setuptools<81"
  log_info "installing Python dependencies"
  "$VENV_DIR/bin/pip" install -r "$requirements_file"
  "$VENV_DIR/bin/pip" install -e "$ODOO_SRC_DIR"
  ensure_python_html_clean_dependency "$VENV_DIR/bin/python" "venv"
  printf '%s\n' "$new_stamp" >"$stamp_file"
}

# Install Odoo from .deb package (Ubuntu/Debian only).
install_deb_package() {
  [[ "$OS_FAMILY" == "linux" ]] || log_fatal ".deb install only supported on Linux"
  [[ "$LINUX_DISTRO" == "ubuntu" || "$LINUX_DISTRO" == "debian" ]] || log_fatal ".deb auto-install is only supported on Ubuntu/Debian"
  [[ -n "$ODOO_DEB_PACKAGE" ]] || ODOO_DEB_PACKAGE="$(pick_file 'odoo*.deb')"
  [[ -n "$ODOO_DEB_PACKAGE" ]] || log_fatal "odoo .deb package not found"

  _verify_package_checksum "$ODOO_DEB_PACKAGE"

  require_cmd apt-get
  log_info "installing Odoo .deb package: $ODOO_DEB_PACKAGE"
  run_privileged env DEBIAN_FRONTEND=noninteractive apt-get install -y "$ODOO_DEB_PACKAGE"
  export ODOO_BIN="/usr/bin/odoo"
  ensure_odoo_runtime_python_dependencies
}

# Install Odoo from .exe package (Windows only, via PowerShell).
install_windows_exe() {
  [[ "$OS_FAMILY" == "windows" ]] || log_fatal ".exe install only supported on Windows"
  [[ -n "$ODOO_EXE_PACKAGE" ]] || ODOO_EXE_PACKAGE="$(pick_file 'odoo*.exe')"
  [[ -n "$ODOO_EXE_PACKAGE" ]] || log_fatal "odoo .exe installer not found"

  _verify_package_checksum "$ODOO_EXE_PACKAGE"

  require_cmd powershell.exe
  log_info "installing Odoo .exe package silently"
  powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "Start-Process -FilePath '$ODOO_EXE_PACKAGE' -ArgumentList '/S' -Verb RunAs -Wait"
}

# Show a summary of selected installation artifacts for user awareness.
show_selected_artifacts() {
  log_info "install mode: $INSTALL_MODE"
  [[ -n "${ODOO_TAR_GZ:-}" ]] && log_info "odoo tar.gz: $ODOO_TAR_GZ"
  [[ -n "${ODOO_DEB_PACKAGE:-}" ]] && log_info "odoo deb: $ODOO_DEB_PACKAGE"
  [[ -n "${ODOO_EXE_PACKAGE:-}" ]] && log_info "odoo exe: $ODOO_EXE_PACKAGE"
  [[ -n "${ODOO_SRC_DIR:-}" ]] && log_info "odoo source dir: $ODOO_SRC_DIR"
  [[ -n "${CUSTOM_ADDONS_DIR:-}" ]] && log_info "custom addons dir: $CUSTOM_ADDONS_DIR"
  [[ -n "${BACKUP_INPUT:-}" ]] && log_info "backup input: $BACKUP_INPUT"
  log_info "db restore mode: $RESTORE_MODE / strategy: $RESTORE_STRATEGY"
}
