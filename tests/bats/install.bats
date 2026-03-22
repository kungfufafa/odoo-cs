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
