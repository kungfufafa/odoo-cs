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
CUSTOM_ADDONS_ZIP_PATTERNS="${CUSTOM_ADDONS_ZIP_PATTERNS:-*addons*.zip|majukendaraanlistrikindonesia-main.zip}"

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
  local patterns_array=($CUSTOM_ADDONS_ZIP_PATTERNS)
  unset IFS

  for pattern in "${patterns_array[@]}"; do
    candidate="$(find "$ROOT" -maxdepth 1 -type f -name "$pattern" | sort | head -n 1 || true)"
    [[ -n "$candidate" ]] && break
  done

  if [[ -n "${candidate:-}" ]]; then
    require_cmd unzip
    extract_dir="$ARTIFACTS_DIR/$(basename "${candidate%.zip}")"
    if [[ ! -f "$extract_dir/.extracted.ok" ]]; then
      rm -rf "$extract_dir"
      mkdir -p "$extract_dir"
      log_info "extracting custom addons zip to $extract_dir"
      unzip -oq "$candidate" -d "$extract_dir"
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
    require_cmd sudo
    require_cmd apt-get
    log_info "installing system packages for $LINUX_DISTRO"
    sudo apt-get update
    sudo DEBIAN_FRONTEND=noninteractive apt-get install -y "${APT_PACKAGES[@]}"
  else
    log_info "skipping auto package install on non-Ubuntu Linux"
  fi
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
    return 0
  fi

  log_info "creating virtualenv at $VENV_DIR"
  python3 -m venv "$VENV_DIR"
  "$VENV_DIR/bin/pip" install --upgrade pip wheel "setuptools<81"
  log_info "installing Python dependencies"
  "$VENV_DIR/bin/pip" install -r "$requirements_file"
  "$VENV_DIR/bin/pip" install -e "$ODOO_SRC_DIR"
  printf '%s\n' "$new_stamp" >"$stamp_file"
}

# Install Odoo from .deb package (Ubuntu/Debian only).
install_deb_package() {
  [[ "$OS_FAMILY" == "linux" ]] || log_fatal ".deb install only supported on Linux"
  [[ "$LINUX_DISTRO" == "ubuntu" || "$LINUX_DISTRO" == "debian" ]] || log_fatal ".deb auto-install is only supported on Ubuntu/Debian"
  [[ -n "$ODOO_DEB_PACKAGE" ]] || ODOO_DEB_PACKAGE="$(pick_file 'odoo*.deb')"
  [[ -n "$ODOO_DEB_PACKAGE" ]] || log_fatal "odoo .deb package not found"

  _verify_package_checksum "$ODOO_DEB_PACKAGE"

  require_cmd sudo
  require_cmd apt-get
  log_info "installing Odoo .deb package: $ODOO_DEB_PACKAGE"
  sudo DEBIAN_FRONTEND=noninteractive apt-get install -y "$ODOO_DEB_PACKAGE"
  ODOO_BIN="/usr/bin/odoo"
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
