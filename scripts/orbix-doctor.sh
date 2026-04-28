#!/usr/bin/env bash
set -Eeuo pipefail

PLATFORM_ROOT=${PLATFORM_ROOT:-/opt/backup-platform}
CONFIG_DIR=${CONFIG_DIR:-/etc/backup}
STATE_DIR=${STATE_DIR:-/var/lib/backup}
LOG_DIR=${LOG_DIR:-/var/log/backup}
UI_STATE_DIR=${UI_STATE_DIR:-/var/lib/orbix-ui}

REQUIRED_COMMANDS=(
  bash
  curl
  rsync
  ssh
  sqlite3
  python3
  docker
  jq
  restic
  find
  du
  tar
  gzip
  systemctl
  journalctl
)

APT_PACKAGES=(
  curl
  rsync
  openssh-client
  sqlite3
  python3
  jq
  restic
  util-linux
  ca-certificates
)

EXECUTABLE_PATHS=(
  "$PLATFORM_ROOT/scripts/backup-runner.sh"
  "$PLATFORM_ROOT/scripts/backup-restore-helper.sh"
  "$PLATFORM_ROOT/scripts/orbix-ops.sh"
  "$PLATFORM_ROOT/scripts/orbix-dispatcher.py"
  "$PLATFORM_ROOT/scripts/orbix-doctor.sh"
  "$PLATFORM_ROOT/hooks/pre_local_rpi.sh"
  "$PLATFORM_ROOT/hooks/pre_remote_generic.sh"
)

MISSING_COMMANDS=()
MISSING_PATHS=()
NONEXEC_PATHS=()

json_escape() {
  python3 - <<'PY' "$1"
import json, sys
print(json.dumps(sys.argv[1]))
PY
}

check_commands() {
  MISSING_COMMANDS=()
  local cmd
  for cmd in "${REQUIRED_COMMANDS[@]}"; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
      MISSING_COMMANDS+=("$cmd")
    fi
  done
}

check_paths() {
  MISSING_PATHS=()
  NONEXEC_PATHS=()
  local path
  for path in "${EXECUTABLE_PATHS[@]}"; do
    if [[ ! -e "$path" ]]; then
      MISSING_PATHS+=("$path")
      continue
    fi
    if [[ ! -x "$path" ]]; then
      NONEXEC_PATHS+=("$path")
    fi
  done
}

ensure_dirs() {
  mkdir -p "$CONFIG_DIR" "$CONFIG_DIR/servers.d" "$STATE_DIR" "$STATE_DIR/catalog" "$LOG_DIR" "$UI_STATE_DIR" "$UI_STATE_DIR/jobs"
}

fix_permissions() {
  local path
  for path in "${EXECUTABLE_PATHS[@]}"; do
    [[ -e "$path" ]] || continue
    chmod +x "$path"
  done
}

install_missing() {
  check_commands
  if [[ ${#MISSING_COMMANDS[@]} -eq 0 ]]; then
    return 0
  fi
  if ! command -v apt-get >/dev/null 2>&1; then
    echo "apt-get not available; cannot auto-install missing commands: ${MISSING_COMMANDS[*]}" >&2
    return 1
  fi
  export DEBIAN_FRONTEND=noninteractive
  apt-get update
  apt-get install -y "${APT_PACKAGES[@]}"
}

summary_text() {
  check_commands
  check_paths
  ensure_dirs
  echo "Orbix doctor summary"
  echo "platform_root=$PLATFORM_ROOT"
  echo "config_dir=$CONFIG_DIR"
  echo "state_dir=$STATE_DIR"
  echo "log_dir=$LOG_DIR"
  echo "ui_state_dir=$UI_STATE_DIR"
  echo "missing_commands=${#MISSING_COMMANDS[@]}"
  local item
  for item in "${MISSING_COMMANDS[@]}"; do
    echo "  - missing command: $item"
  done
  echo "missing_paths=${#MISSING_PATHS[@]}"
  for item in "${MISSING_PATHS[@]}"; do
    echo "  - missing path: $item"
  done
  echo "nonexec_paths=${#NONEXEC_PATHS[@]}"
  for item in "${NONEXEC_PATHS[@]}"; do
    echo "  - non executable: $item"
  done
}

summary_json() {
  check_commands
  check_paths
  ensure_dirs
  python3 - <<'PY' "$PLATFORM_ROOT" "$CONFIG_DIR" "$STATE_DIR" "$LOG_DIR" "$UI_STATE_DIR" "$(printf '%s\n' "${MISSING_COMMANDS[@]}")" "$(printf '%s\n' "${MISSING_PATHS[@]}")" "$(printf '%s\n' "${NONEXEC_PATHS[@]}")"
import json, sys
platform_root, config_dir, state_dir, log_dir, ui_state_dir, missing_cmds, missing_paths, nonexec_paths = sys.argv[1:9]
def lines(blob):
    return [line for line in blob.splitlines() if line]
payload = {
    "ok": not (lines(missing_cmds) or lines(missing_paths) or lines(nonexec_paths)),
    "platform_root": platform_root,
    "config_dir": config_dir,
    "state_dir": state_dir,
    "log_dir": log_dir,
    "ui_state_dir": ui_state_dir,
    "missing_commands": lines(missing_cmds),
    "missing_paths": lines(missing_paths),
    "nonexec_paths": lines(nonexec_paths),
}
print(json.dumps(payload))
PY
}

usage() {
  cat <<'EOF'
Usage:
  orbix-doctor.sh check [--json]
  orbix-doctor.sh fix-perms
  orbix-doctor.sh install-missing
  orbix-doctor.sh bootstrap
EOF
}

cmd="${1:-check}"
format="${2:-}"

case "$cmd" in
  check)
    if [[ "$format" == "--json" ]]; then
      summary_json
    else
      summary_text
    fi
    ;;
  fix-perms)
    ensure_dirs
    fix_permissions
    summary_text
    ;;
  install-missing)
    ensure_dirs
    install_missing
    summary_text
    ;;
  bootstrap)
    ensure_dirs
    fix_permissions
    install_missing
    summary_text
    ;;
  *)
    usage
    exit 1
    ;;
esac
