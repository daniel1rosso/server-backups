#!/usr/bin/env bash
set -Eeuo pipefail

GLOBAL_ENV=${GLOBAL_ENV:-/etc/backup/global.env}
SERVER_DIR=${SERVER_DIR:-/etc/backup/servers.d}

if [[ ! -f "$GLOBAL_ENV" ]]; then
  echo "missing global env: $GLOBAL_ENV" >&2
  exit 1
fi

source "$GLOBAL_ENV"

mkdir -p "$STATE_DIR" "$LOG_DIR" "$TMP_DIR" "$STATE_DIR/catalog"

CATALOG_DB="$STATE_DIR/catalog/backups.sqlite3"
RUN_TS=$(date -u +%Y-%m-%dT%H:%M:%SZ)
RUN_LOG="$LOG_DIR/backup-runner-$(date +%F).log"

log() {
  printf '%s %s\n' "$(date '+%F %T')" "$*" | tee -a "$RUN_LOG" >&2
}

notification_enabled() {
  local key="$1"
  local default_value="${2:-false}"
  local value="${!key:-$default_value}"
  [[ "${value,,}" == "true" || "$value" == "1" || "${value,,}" == "yes" || "${value,,}" == "on" ]]
}

telegram_send() {
  local text="$1"
  if [[ "${TELEGRAM_ENABLED:-false}" != "true" ]]; then
    return 0
  fi
  if [[ -z "${TELEGRAM_BOT_TOKEN:-}" || -z "${TELEGRAM_CHAT_ID:-}" ]]; then
    return 0
  fi
  curl -fsS -X POST "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
    -d "chat_id=${TELEGRAM_CHAT_ID}" \
    --data-urlencode "text=${text}" >/dev/null || true
}

telegram_send_if_enabled() {
  local key="$1"
  local text="$2"
  local default_value="${3:-false}"
  notification_enabled "$key" "$default_value" || return 0
  telegram_send "$text"
}

init_catalog() {
  sqlite3 "$CATALOG_DB" <<'SQL'
create table if not exists runs (
  id integer primary key autoincrement,
  server_id text not null,
  source_role text not null,
  snapshot_id text,
  restic_short_id text,
  group_name text not null,
  status text not null,
  repo text not null,
  created_at text not null,
  started_at text,
  finished_at text,
  paths_json text not null,
  source_size_bytes integer default 0,
  processed_bytes integer default 0,
  file_count integer default 0,
  duration_seconds integer default 0,
  error_message text
);
SQL
  sqlite3 "$CATALOG_DB" "alter table runs add column started_at text;" 2>/dev/null || true
  sqlite3 "$CATALOG_DB" "alter table runs add column finished_at text;" 2>/dev/null || true
  sqlite3 "$CATALOG_DB" "alter table runs add column source_size_bytes integer default 0;" 2>/dev/null || true
  sqlite3 "$CATALOG_DB" "alter table runs add column processed_bytes integer default 0;" 2>/dev/null || true
  sqlite3 "$CATALOG_DB" "alter table runs add column file_count integer default 0;" 2>/dev/null || true
  sqlite3 "$CATALOG_DB" "alter table runs add column duration_seconds integer default 0;" 2>/dev/null || true
  sqlite3 "$CATALOG_DB" "alter table runs add column error_message text;" 2>/dev/null || true
}

restic_cmd() {
  if [[ -n "${RESTIC_SFTP_COMMAND:-}" ]]; then
    restic -o "sftp.command=${RESTIC_SFTP_COMMAND}" "$@"
  else
    restic "$@"
  fi
}

safe_source() {
  local file="$1"
  set -a
  source "$file"
  set +a
}

ensure_restic_repo() {
  local repo="$1"
  export RESTIC_REPOSITORY="$repo"
  export RESTIC_PASSWORD_FILE
  export RESTIC_PASSWORD_COMMAND=
  export RESTIC_CACHE_DIR="$STATE_DIR/cache"
  mkdir -p "$RESTIC_CACHE_DIR"
  if ! restic_cmd snapshots >/dev/null 2>&1; then
    restic_cmd init >/dev/null
  fi
}

catalog_snapshot() {
  local server_id="$1"
  local source_role="$2"
  local group_name="$3"
  local repo="$4"
  local status="$5"
  local paths_json="$6"
  local started_at="$7"
  local finished_at="$8"
  local source_size_bytes="$9"
  local processed_bytes="${10}"
  local file_count="${11}"
  local duration_seconds="${12}"
  local error_message="${13}"
  local snapshot_json
  snapshot_json=$(restic_cmd snapshots --latest 1 --json)
  local snapshot_id short_id
  snapshot_id=$(jq -r '.[0].id // ""' <<<"$snapshot_json")
  short_id=$(jq -r '.[0].short_id // ""' <<<"$snapshot_json")
  sqlite3 "$CATALOG_DB" <<SQL
insert into runs(server_id, source_role, snapshot_id, restic_short_id, group_name, status, repo, created_at, started_at, finished_at, paths_json, source_size_bytes, processed_bytes, file_count, duration_seconds, error_message)
values (
  '$(printf "%s" "$server_id" | sed "s/'/''/g")',
  '$(printf "%s" "$source_role" | sed "s/'/''/g")',
  '$(printf "%s" "$snapshot_id" | sed "s/'/''/g")',
  '$(printf "%s" "$short_id" | sed "s/'/''/g")',
  '$(printf "%s" "$group_name" | sed "s/'/''/g")',
  '$(printf "%s" "$status" | sed "s/'/''/g")',
  '$(printf "%s" "$repo" | sed "s/'/''/g")',
  '$(printf "%s" "$RUN_TS" | sed "s/'/''/g")',
  '$(printf "%s" "$started_at" | sed "s/'/''/g")',
  '$(printf "%s" "$finished_at" | sed "s/'/''/g")',
  '$(printf "%s" "$paths_json" | sed "s/'/''/g")',
  ${source_size_bytes:-0},
  ${processed_bytes:-0},
  ${file_count:-0},
  ${duration_seconds:-0},
  '$(printf "%s" "$error_message" | sed "s/'/''/g")'
);
SQL
}

run_server() {
  local env_file="$1"
  unset SERVER_ID SOURCE_ROLE SOURCE_MODE HOOK_SCRIPT HOST_PATHS HOST_PATHS_OPTIONAL
  unset DOCKER_VOLUMES DOKPLOY_POSTGRES_CONTAINER DOKPLOY_POSTGRES_USER DOKPLOY_POSTGRES_DB
  unset REMOTE_HOST REMOTE_PORT REMOTE_USER REMOTE_SSH_KEY REMOTE_PATHS REMOTE_PATHS_OPTIONAL
  unset REMOTE_PRE_DUMP_COMMANDS REMOTE_POSTGRES_CONTAINERS REMOTE_DOCKER_VOLUMES

  safe_source "$env_file"

  if [[ -z "${SERVER_ID:-}" || -z "${HOOK_SCRIPT:-}" ]]; then
    log "skipping invalid server env: $env_file"
    return 1
  fi

  local hook_path="${BACKUP_ROOT}/${HOOK_SCRIPT}"
  local repo="sftp:${SFTP_REPO_USER}@${SFTP_REPO_HOST}:${SFTP_REPO_BASE}/${SERVER_ID}"
  local staging="$TMP_DIR/${SERVER_ID}/$(date +%F_%H%M%S)"
  mkdir -p "$staging"

  log "[$SERVER_ID] start"
  telegram_send_if_enabled "TELEGRAM_NOTIFY_BACKUP_START" "Backup start: ${SERVER_ID} (${SOURCE_ROLE:-unknown})" "true"

  ensure_restic_repo "$repo"

  if ! BACKUP_STAGING="$staging" BACKUP_ROOT="$BACKUP_ROOT" bash "$hook_path"; then
    telegram_send_if_enabled "TELEGRAM_NOTIFY_BACKUP_FAILURE" "Backup failed: ${SERVER_ID} hook ${HOOK_SCRIPT} devolvio error" "true"
    rm -rf "$staging"
    return 1
  fi

  local had_group=false
  shopt -s nullglob
  for group_dir in "$staging"/*; do
    [[ -d "$group_dir" ]] || continue
    had_group=true
    local group_name paths_json group_started_at group_finished_at group_start_epoch group_end_epoch
    local source_size_bytes file_count processed_bytes duration_seconds summary_json restic_output status error_message
    group_name=$(basename "$group_dir")
    group_started_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    group_start_epoch=$(date +%s)
    paths_json=$(find "$group_dir" -mindepth 1 -maxdepth 5 -printf '%P\n' | jq -R -s -c 'split("\n")[:-1]')
    source_size_bytes=$(du -sb "$group_dir" | awk '{print $1}')
    file_count=$(find "$group_dir" -type f | wc -l | tr -d ' ')
    restic_output=$(mktemp)
    log "[$SERVER_ID] backup group $group_name"
    set +e
    restic_cmd backup "$group_dir" --json \
      --host "$SERVER_ID" \
      --tag "server:${SERVER_ID}" \
      --tag "role:${SOURCE_ROLE:-unknown}" \
      --tag "group:${group_name}" \
      --tag "source_mode:${SOURCE_MODE:-unknown}" \
      >"$restic_output" 2>>"$RUN_LOG"
    status_code=$?
    set -e
    group_finished_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    group_end_epoch=$(date +%s)
    duration_seconds=$((group_end_epoch - group_start_epoch))
    summary_json=$(jq -s 'map(select(.message_type == "summary")) | last // {}' "$restic_output")
    processed_bytes=$(jq -r '.total_bytes_processed // 0' <<<"$summary_json")
    status="ok"
    error_message=""
    if [[ $status_code -ne 0 ]]; then
      status="failed"
      error_message="restic backup failed for group ${group_name}"
    fi
    cat "$restic_output" >>"$RUN_LOG"
    rm -f "$restic_output"
    catalog_snapshot \
      "$SERVER_ID" \
      "${SOURCE_ROLE:-unknown}" \
      "$group_name" \
      "$repo" \
      "$status" \
      "$paths_json" \
      "$group_started_at" \
      "$group_finished_at" \
      "$source_size_bytes" \
      "$processed_bytes" \
      "$file_count" \
      "$duration_seconds" \
      "$error_message"
    if [[ $status_code -ne 0 ]]; then
      telegram_send_if_enabled "TELEGRAM_NOTIFY_BACKUP_FAILURE" "Backup failed: ${SERVER_ID} group ${group_name} devolvio error en restic" "true"
      rm -rf "$staging"
      return "$status_code"
    fi
  done
  shopt -u nullglob

  if [[ "$had_group" == false ]]; then
    log "[$SERVER_ID] no groups generated"
    telegram_send_if_enabled "TELEGRAM_NOTIFY_BACKUP_FAILURE" "Backup failed: ${SERVER_ID} no genero grupos de backup" "true"
    rm -rf "$staging"
    return 1
  fi

  restic_cmd forget --keep-daily "${RETENTION_DAILY:-${RESTIC_RETENTION_DAILY:-7}}" \
    --keep-weekly "${RETENTION_WEEKLY:-${RESTIC_RETENTION_WEEKLY:-4}}" \
    --keep-monthly "${RETENTION_MONTHLY:-${RESTIC_RETENTION_MONTHLY:-6}}" \
    --prune >>"$RUN_LOG" 2>&1

  restic_cmd snapshots --json > "$STATE_DIR/catalog/${SERVER_ID}-snapshots.json"
  log "[$SERVER_ID] done"
  telegram_send_if_enabled "TELEGRAM_NOTIFY_BACKUP_SUCCESS" "Backup OK: ${SERVER_ID} finalizado. Repo ${repo}" "true"
  rm -rf "$staging"
}

main() {
  init_catalog
  if [[ $# -gt 0 ]]; then
    run_server "$SERVER_DIR/$1"
    return
  fi
  local file
  shopt -s nullglob
  for file in "$SERVER_DIR"/*.env; do
    run_server "$file"
  done
  shopt -u nullglob
}

main "$@"
