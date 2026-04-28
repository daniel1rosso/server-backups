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
  backup-restore-helper.sh restore <server_id> <snapshot_id> <target_dir>
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

cmd="${1:-}"
case "$cmd" in
  list)
    sqlite3 -header -column "$CATALOG_DB" \
      "select server_id, source_role, group_name, restic_short_id, created_at from runs order by id desc;"
    ;;
  snapshots)
    server_id="${2:?missing server_id}"
    export RESTIC_REPOSITORY
    RESTIC_REPOSITORY=$(repo_for_server "$server_id")
    export RESTIC_PASSWORD_FILE
    restic_cmd snapshots
    ;;
  restore)
    server_id="${2:?missing server_id}"
    snapshot_id="${3:?missing snapshot_id}"
    target_dir="${4:?missing target_dir}"
    export RESTIC_REPOSITORY
    RESTIC_REPOSITORY=$(repo_for_server "$server_id")
    export RESTIC_PASSWORD_FILE
    mkdir -p "$target_dir"
    restic_cmd restore "$snapshot_id" --target "$target_dir"
    ;;
  *)
    usage
    exit 1
    ;;
esac
