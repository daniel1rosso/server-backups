#!/usr/bin/env bash
set -Eeuo pipefail

GLOBAL_ENV=${GLOBAL_ENV:-/etc/backup/global.env}

if [[ ! -f "$GLOBAL_ENV" ]]; then
  echo "missing global env: $GLOBAL_ENV" >&2
  exit 1
fi

source "$GLOBAL_ENV"

CATALOG_DB="$STATE_DIR/catalog/backups.sqlite3"

usage() {
  cat <<'EOF'
Usage:
  backup-restore-helper.sh list
  backup-restore-helper.sh snapshots <server_id>
  backup-restore-helper.sh ls <server_id> <snapshot_id> [snapshot_subpath]
  backup-restore-helper.sh verify <server_id> <snapshot_or_ref> <target_dir> [--include <path> ...]
  backup-restore-helper.sh restore <server_id> <snapshot_or_ref> <target_dir> [--include <path> ...]
EOF
}

repo_for_server() {
  local server_id="$1"
  printf 'sftp:%s@%s:%s/%s' "$SFTP_REPO_USER" "$SFTP_REPO_HOST" "$SFTP_REPO_BASE" "$server_id"
}

restic_cmd() {
  if [[ -n "${RESTIC_SFTP_COMMAND:-}" ]]; then
    restic -o "sftp.command=${RESTIC_SFTP_COMMAND}" "$@"
  else
    restic "$@"
  fi
}

setup_repo() {
  local server_id="$1"
  export RESTIC_REPOSITORY
  RESTIC_REPOSITORY=$(repo_for_server "$server_id")
  export RESTIC_PASSWORD_FILE
}

ensure_safe_target() {
  local target_dir="$1"
  if [[ "$target_dir" != /* ]]; then
    echo "target_dir must be an absolute path: $target_dir" >&2
    exit 1
  fi
  if [[ "$target_dir" == "/" ]]; then
    echo "refusing to restore on /" >&2
    exit 1
  fi
}

verify_snapshot() {
  local snapshot_ref="$1"
  local snapshot_selector="${snapshot_ref%%:*}"
  restic_cmd snapshots "$snapshot_selector" --json >/dev/null
}

parse_restore_args() {
  RESTORE_INCLUDE_ARGS=()
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --include)
        [[ $# -ge 2 ]] || { echo "missing value for --include" >&2; exit 1; }
        RESTORE_INCLUDE_ARGS+=("--include" "$2")
        shift 2
        ;;
      *)
        echo "unsupported restore option: $1" >&2
        exit 1
        ;;
    esac
  done
}

verify_restore() {
  local server_id="$1"
  local snapshot_ref="$2"
  local target_dir="$3"
  shift 3
  parse_restore_args "$@"
  setup_repo "$server_id"
  ensure_safe_target "$target_dir"
  verify_snapshot "$snapshot_ref"
  echo "server_id=$server_id"
  echo "repository=$RESTIC_REPOSITORY"
  echo "snapshot_ref=$snapshot_ref"
  echo "target_dir=$target_dir"
  if [[ ${#RESTORE_INCLUDE_ARGS[@]} -gt 0 ]]; then
    printf 'includes='
    printf '%s ' "${RESTORE_INCLUDE_ARGS[@]}"
    printf '\n'
  fi
}

cmd="${1:-}"
case "$cmd" in
  list)
    sqlite3 -header -column "$CATALOG_DB" \
      "select server_id, source_role, group_name, restic_short_id, created_at from runs order by id desc;"
    ;;
  snapshots)
    server_id="${2:?missing server_id}"
    setup_repo "$server_id"
    restic_cmd snapshots
    ;;
  ls)
    server_id="${2:?missing server_id}"
    snapshot_id="${3:?missing snapshot_id}"
    snapshot_subpath="${4:-}"
    setup_repo "$server_id"
    if [[ -n "$snapshot_subpath" ]]; then
      restic_cmd ls "${snapshot_id}:${snapshot_subpath}"
    else
      restic_cmd ls "$snapshot_id"
    fi
    ;;
  verify)
    server_id="${2:?missing server_id}"
    snapshot_ref="${3:?missing snapshot_or_ref}"
    target_dir="${4:?missing target_dir}"
    shift 4
    verify_restore "$server_id" "$snapshot_ref" "$target_dir" "$@"
    ;;
  restore)
    server_id="${2:?missing server_id}"
    snapshot_ref="${3:?missing snapshot_or_ref}"
    target_dir="${4:?missing target_dir}"
    shift 4
    verify_restore "$server_id" "$snapshot_ref" "$target_dir" "$@"
    mkdir -p "$target_dir"
    restic_cmd restore "$snapshot_ref" --target "$target_dir" "${RESTORE_INCLUDE_ARGS[@]}"
    ;;
  *)
    usage
    exit 1
    ;;
esac
