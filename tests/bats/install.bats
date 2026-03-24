#!/usr/bin/env bats
# ============================================================================
# install.bats — Unit tests for lib/install.sh
# ============================================================================

load test_helper

setup() {
  setup_test_environment
  load_module "platform.sh"
  load_module "install.sh"
}

teardown() {
  teardown_test_environment
}

@test "detect_custom_addons extracts zip with python fallback when unzip is unavailable" {
  python3 - <<PY
import pathlib
import zipfile

root = pathlib.Path(r"$ROOT")
with zipfile.ZipFile(root / "custom-addons.zip", "w") as archive:
    archive.writestr("custom_module/__manifest__.py", "{'name': 'Custom Module'}\n")
PY

  export CUSTOM_ADDONS_ZIP_PATTERNS="custom-addons.zip"

  command() {
    if [[ "$1" == "-v" && "$2" == "unzip" ]]; then
      return 1
    fi
    builtin command "$@"
  }

  result="$(detect_custom_addons)"

  [ "$result" = "$ARTIFACTS_DIR/custom-addons/custom_module" ]
  [ -f "$result/__manifest__.py" ]
}

@test "setup_python_env verifies html_clean even when reusing an existing virtualenv" {
  export ODOO_SRC_DIR="$ROOT/odoo-src"
  mkdir -p "$ODOO_SRC_DIR" "$VENV_DIR/bin"
  printf 'lxml\n' > "$ODOO_SRC_DIR/requirements.txt"
  touch "$VENV_DIR/bin/python"
  chmod +x "$VENV_DIR/bin/python"

  stamp="$(cksum "$ODOO_SRC_DIR/requirements.txt"; printf '%s\n' "$ODOO_SRC_DIR")"
  printf '%s\n' "$stamp" > "$VENV_DIR/.requirements.stamp"

  require_cmd() { :; }
  ensure_python_html_clean_dependency() {
    printf '%s|%s\n' "$1" "$2" > "$ROOT/ensure.log"
  }

  setup_python_env

  grep -q "$VENV_DIR/bin/python|venv" "$ROOT/ensure.log"
}

@test "resolve_python_bin_from_shebang handles env -S python3 shebangs" {
  export PATH="$MOCK_BIN:$PATH"
  create_mock "python3" ""

  script_path="$ROOT/odoo-wrapper"
  cat > "$script_path" <<'EOF'
#!/usr/bin/env -S python3 -Es
print("ok")
EOF
  chmod +x "$script_path"

  result="$(resolve_python_bin_from_shebang "$script_path")"

  [ "$result" = "$MOCK_BIN/python3" ]
}

@test "ensure_python_html_clean_dependency falls back to pip when apt package is insufficient" {
  export LINUX_DISTRO="ubuntu"
  export PATH="$MOCK_BIN:$PATH"
  create_mock "apt-get" ""

  python_has_lxml_html_clean() {
    [[ -f "$ROOT/html-clean.ready" ]]
  }

  run_privileged() {
    printf '%s\n' "$*" >> "$ROOT/install.log"
    return 0
  }

  run_python_pip_install() {
    printf 'pip|%s|%s|%s\n' "$1" "$2" "$3" >> "$ROOT/install.log"
    touch "$ROOT/html-clean.ready"
  }

  ensure_python_html_clean_dependency "/usr/bin/python3" "system"

  grep -q "env DEBIAN_FRONTEND=noninteractive apt-get install -y python3-lxml-html-clean" "$ROOT/install.log"
  grep -q "pip|1|/usr/bin/python3|lxml_html_clean" "$ROOT/install.log"
}

@test "ensure_odoo_runtime_python_dependencies resolves runtime python from ODOO_BIN" {
  export PATH="$MOCK_BIN:$PATH"
  export ODOO_BIN="$ROOT/odoo-bin"
  create_mock "python3" ""

  cat > "$ODOO_BIN" <<'EOF'
#!/usr/bin/env python3
print("odoo")
EOF
  chmod +x "$ODOO_BIN"

  python_has_lxml_html_clean() {
    return 1
  }

  ensure_python_html_clean_dependency() {
    printf '%s|%s\n' "$1" "$2" > "$ROOT/runtime-ensure.log"
  }

  ensure_odoo_runtime_python_dependencies

  grep -q "$MOCK_BIN/python3|system" "$ROOT/runtime-ensure.log"
}

@test "install_deb_package ensures html_clean dependency after apt install" {
  export OS_FAMILY="linux"
  export LINUX_DISTRO="ubuntu"
  export PATH="$MOCK_BIN:$PATH"
  export ODOO_DEB_PACKAGE="$ROOT/odoo_16.deb"
  touch "$ODOO_DEB_PACKAGE"
  create_mock "apt-get" ""

  require_cmd() { :; }
  run_privileged() { :; }
  ensure_odoo_runtime_python_dependencies() {
    printf 'runtime-preflight\n' > "$ROOT/deb-ensure.log"
  }

  install_deb_package

  [ "$ODOO_BIN" = "/usr/bin/odoo" ]
  grep -q "runtime-preflight" "$ROOT/deb-ensure.log"
}
