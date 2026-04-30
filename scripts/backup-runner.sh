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
  error_message text,
  snapshot_version text,
  manifest_json text
);
SQL
  sqlite3 "$CATALOG_DB" "alter table runs add column started_at text;" 2>/dev/null || true
  sqlite3 "$CATALOG_DB" "alter table runs add column finished_at text;" 2>/dev/null || true
  sqlite3 "$CATALOG_DB" "alter table runs add column source_size_bytes integer default 0;" 2>/dev/null || true
  sqlite3 "$CATALOG_DB" "alter table runs add column processed_bytes integer default 0;" 2>/dev/null || true
  sqlite3 "$CATALOG_DB" "alter table runs add column file_count integer default 0;" 2>/dev/null || true
  sqlite3 "$CATALOG_DB" "alter table runs add column duration_seconds integer default 0;" 2>/dev/null || true
  sqlite3 "$CATALOG_DB" "alter table runs add column error_message text;" 2>/dev/null || true
  sqlite3 "$CATALOG_DB" "alter table runs add column snapshot_version text;" 2>/dev/null || true
  sqlite3 "$CATALOG_DB" "alter table runs add column manifest_json text;" 2>/dev/null || true
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
  local snapshot_version="${14}"
  local manifest_json="${15}"
  local snapshot_json
  snapshot_json=$(restic_cmd snapshots --latest 1 --json)
  local snapshot_id short_id
  snapshot_id=$(jq -r '.[0].id // ""' <<<"$snapshot_json")
  short_id=$(jq -r '.[0].short_id // ""' <<<"$snapshot_json")
  sqlite3 "$CATALOG_DB" <<SQL
insert into runs(server_id, source_role, snapshot_id, restic_short_id, group_name, status, repo, created_at, started_at, finished_at, paths_json, source_size_bytes, processed_bytes, file_count, duration_seconds, error_message, snapshot_version, manifest_json)
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
  '$(printf "%s" "$error_message" | sed "s/'/''/g")',
  '$(printf "%s" "$snapshot_version" | sed "s/'/''/g")',
  '$(printf "%s" "$manifest_json" | sed "s/'/''/g")'
);
SQL
}

infer_required_apt_packages() {
  local packages=()
  packages+=("rsync" "curl")
  if [[ -n "${DOCKER_VOLUMES:-}${REMOTE_DOCKER_VOLUMES:-}${COMPOSE_PROJECT_PATHS:-}${DOCKER_CHECK_ENABLED:-}${DOCKER_ALERT_CONTAINERS:-}" ]]; then
    packages+=("docker.io" "docker-compose-v2")
  fi
  if [[ -n "${K8S_MANIFEST_PATHS:-}${K8S_CHECK_ENABLED:-}" ]]; then
    packages+=("kubectl")
  fi
  if [[ -n "${LOCAL_POSTGRES_DUMPS:-}${REMOTE_POSTGRES_DUMPS:-}${DOKPLOY_POSTGRES_CONTAINER:-}" ]]; then
    packages+=("postgresql-client")
  fi
  if [[ -n "${LOCAL_MYSQL_DUMPS:-}${REMOTE_MYSQL_DUMPS:-}" ]]; then
    packages+=("default-mysql-client")
  fi
  if [[ -n "${LOCAL_MONGO_DUMPS:-}${REMOTE_MONGO_DUMPS:-}" ]]; then
    packages+=("mongodb-database-tools")
  fi
  if [[ -n "${RESTORE_REQUIRED_APT_PACKAGES:-}" ]]; then
    local extra
    for extra in ${RESTORE_REQUIRED_APT_PACKAGES}; do
      packages+=("$extra")
    done
  fi
  printf '%s\n' "${packages[@]}" | awk 'NF' | sort -u
}

write_snapshot_manifest() {
  local staging="$1"
  local manifest_path="$staging/snapshot-manifest.json"
  local required_packages_json
  required_packages_json=$(infer_required_apt_packages | jq -R -s -c 'split("\n")[:-1]')
  STAGING_DIR="$staging" MANIFEST_PATH="$manifest_path" REQUIRED_PACKAGES_JSON="$required_packages_json" python3 <<'PY'
import json
import os
from pathlib import Path

staging = Path(os.environ["STAGING_DIR"])
manifest_path = Path(os.environ["MANIFEST_PATH"])

def split_shellish(value: str) -> list[str]:
    return [item for item in value.split() if item]

def parse_semicolon_entries(value: str) -> list[list[str]]:
    entries: list[list[str]] = []
    for raw in (value or "").split(";"):
        raw = raw.strip()
        if not raw:
            continue
        entries.append([part.strip() for part in raw.split("|")])
    return entries

def basename_label(path: str, fallback: str) -> str:
    cleaned = path.rstrip("/") or path
    name = Path(cleaned).name or fallback
    return name.replace("/", "-")

def mapped_system_paths(env_key: str) -> list[dict[str, str]]:
    items = []
    for source in split_shellish(os.environ.get(env_key, "")):
        label = basename_label(source, "path")
        items.append({"source": source, "snapshot_path": f"system/{label}"})
    return items

def mapped_project_paths(env_key: str, root: str) -> list[dict[str, str]]:
    items = []
    for idx, parts in enumerate(parse_semicolon_entries(os.environ.get(env_key, "")), start=1):
        if len(parts) >= 2:
            label, source = parts[0], parts[1]
        else:
            source = parts[0]
            label = basename_label(source, f"{root}-{idx}")
        items.append({"label": label, "source": source, "snapshot_path": f"{root}/{label}"})
    return items

def mapped_dump_entries(env_key: str, suffix: str) -> list[dict[str, str]]:
    items = []
    for parts in parse_semicolon_entries(os.environ.get(env_key, "")):
        label = parts[0]
        items.append({"label": label, "snapshot_path": f"db-dumps/{label}.{suffix}"})
    return items

system_paths = mapped_system_paths("HOST_PATHS") + mapped_system_paths("HOST_PATHS_OPTIONAL") + mapped_system_paths("REMOTE_PATHS") + mapped_system_paths("REMOTE_PATHS_OPTIONAL")
docker_volumes = [{"name": name, "snapshot_path": f"docker-volumes/{name}.tar.gz"} for name in split_shellish(os.environ.get("DOCKER_VOLUMES", "") or os.environ.get("REMOTE_DOCKER_VOLUMES", ""))]
compose_projects = mapped_project_paths("COMPOSE_PROJECT_PATHS", "compose-projects")
k8s_manifests = mapped_project_paths("K8S_MANIFEST_PATHS", "k8s-manifests")
postgres_dumps = mapped_dump_entries("LOCAL_POSTGRES_DUMPS", "postgres.sql") + mapped_dump_entries("REMOTE_POSTGRES_DUMPS", "postgres.sql")
mysql_dumps = mapped_dump_entries("LOCAL_MYSQL_DUMPS", "mysql.sql") + mapped_dump_entries("REMOTE_MYSQL_DUMPS", "mysql.sql")
mongo_dumps = mapped_dump_entries("LOCAL_MONGO_DUMPS", "mongo.archive") + mapped_dump_entries("REMOTE_MONGO_DUMPS", "mongo.archive")

manifest = {
    "snapshot_version": "orbix-v2",
    "created_at": os.environ.get("RUN_TS", ""),
    "server": {
        "server_id": os.environ.get("SERVER_ID", ""),
        "source_role": os.environ.get("SOURCE_ROLE", ""),
        "source_mode": os.environ.get("SOURCE_MODE", ""),
        "profile_filename": Path(os.environ.get("ENV_FILE_PATH", "")).name if os.environ.get("ENV_FILE_PATH") else "",
    },
    "restore": {
        "required_apt_packages": json.loads(os.environ.get("REQUIRED_PACKAGES_JSON", "[]")),
        "systemd_services": split_shellish(os.environ.get("RESTORE_SYSTEMD_SERVICES", "")),
        "allow_cross_host": True,
        "default_mode": "full-auto",
        "legacy_fallback": True,
    },
    "artifacts": {
        "system_paths": system_paths,
        "compose_projects": compose_projects,
        "k8s_manifests": k8s_manifests,
        "docker_volumes": docker_volumes,
        "postgres_dumps": postgres_dumps,
        "mysql_dumps": mysql_dumps,
        "mongo_dumps": mongo_dumps,
        "dokploy_config": "dokploy-config" if (staging / "dokploy-config").exists() else "",
        "dokploy_db_dump": "dokploy-db/dokploy.sql" if (staging / "dokploy-db" / "dokploy.sql").exists() else "",
    },
    "runtime": {
        "docker_expected": bool(docker_volumes or compose_projects or os.environ.get("DOCKER_EXPORT", "") == "true" or os.environ.get("REMOTE_DOCKER_EXPORT", "") == "true"),
        "kubernetes_expected": bool(k8s_manifests),
        "systemd_expected": bool(os.environ.get("SYSTEMD_EXPORT", "") == "true" or os.environ.get("REMOTE_SYSTEM_EXPORT", "") == "true" or os.environ.get("RESTORE_SYSTEMD_SERVICES", "")),
    },
}

manifest_path.write_text(json.dumps(manifest, indent=2) + "\n")
print(json.dumps(manifest, separators=(",", ":")))
PY
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

  if ! BACKUP_STAGING="$staging" BACKUP_ROOT="$BACKUP_ROOT" ENV_FILE_PATH="$env_file" RUN_TS="$RUN_TS" bash "$hook_path"; then
    telegram_send_if_enabled "TELEGRAM_NOTIFY_BACKUP_FAILURE" "Backup failed: ${SERVER_ID} hook ${HOOK_SCRIPT} devolvio error" "true"
    rm -rf "$staging"
    return 1
  fi

  local has_snapshot_content=false
  shopt -s nullglob dotglob
  for item in "$staging"/*; do
    if [[ -e "$item" ]]; then
      has_snapshot_content=true
      break
    fi
  done
  shopt -u nullglob dotglob

  if [[ "$has_snapshot_content" == false ]]; then
    log "[$SERVER_ID] no groups generated"
    telegram_send_if_enabled "TELEGRAM_NOTIFY_BACKUP_FAILURE" "Backup failed: ${SERVER_ID} no genero grupos de backup" "true"
    rm -rf "$staging"
    return 1
  fi

  local manifest_json paths_json run_started_at run_finished_at run_start_epoch run_end_epoch
  local source_size_bytes file_count processed_bytes duration_seconds summary_json restic_output status error_message
  manifest_json=$(ENV_FILE_PATH="$env_file" RUN_TS="$RUN_TS" SERVER_ID="$SERVER_ID" SOURCE_ROLE="${SOURCE_ROLE:-unknown}" SOURCE_MODE="${SOURCE_MODE:-unknown}" \
    HOOK_SCRIPT="${HOOK_SCRIPT:-}" HOST_PATHS="${HOST_PATHS:-}" HOST_PATHS_OPTIONAL="${HOST_PATHS_OPTIONAL:-}" REMOTE_PATHS="${REMOTE_PATHS:-}" REMOTE_PATHS_OPTIONAL="${REMOTE_PATHS_OPTIONAL:-}" \
    DOCKER_VOLUMES="${DOCKER_VOLUMES:-}" REMOTE_DOCKER_VOLUMES="${REMOTE_DOCKER_VOLUMES:-}" LOCAL_POSTGRES_DUMPS="${LOCAL_POSTGRES_DUMPS:-}" REMOTE_POSTGRES_DUMPS="${REMOTE_POSTGRES_DUMPS:-}" \
    LOCAL_MYSQL_DUMPS="${LOCAL_MYSQL_DUMPS:-}" REMOTE_MYSQL_DUMPS="${REMOTE_MYSQL_DUMPS:-}" LOCAL_MONGO_DUMPS="${LOCAL_MONGO_DUMPS:-}" REMOTE_MONGO_DUMPS="${REMOTE_MONGO_DUMPS:-}" \
    DOKPLOY_POSTGRES_CONTAINER="${DOKPLOY_POSTGRES_CONTAINER:-}" SYSTEMD_EXPORT="${SYSTEMD_EXPORT:-}" REMOTE_SYSTEM_EXPORT="${REMOTE_SYSTEM_EXPORT:-}" DOCKER_EXPORT="${DOCKER_EXPORT:-}" \
    REMOTE_DOCKER_EXPORT="${REMOTE_DOCKER_EXPORT:-}" RESTORE_REQUIRED_APT_PACKAGES="${RESTORE_REQUIRED_APT_PACKAGES:-}" RESTORE_SYSTEMD_SERVICES="${RESTORE_SYSTEMD_SERVICES:-}" \
    COMPOSE_PROJECT_PATHS="${COMPOSE_PROJECT_PATHS:-}" K8S_MANIFEST_PATHS="${K8S_MANIFEST_PATHS:-}" write_snapshot_manifest "$staging")
  paths_json=$(find "$staging" -mindepth 1 -maxdepth 6 -printf '%P\n' | jq -R -s -c 'split("\n")[:-1]')
  source_size_bytes=$(du -sb "$staging" | awk '{print $1}')
  file_count=$(find "$staging" -type f | wc -l | tr -d ' ')
  restic_output=$(mktemp)
  run_started_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  run_start_epoch=$(date +%s)
  log "[$SERVER_ID] backup snapshot root"
  set +e
  restic_cmd backup "$staging" --json \
    --host "$SERVER_ID" \
    --tag "server:${SERVER_ID}" \
    --tag "role:${SOURCE_ROLE:-unknown}" \
    --tag "group:full" \
    --tag "source_mode:${SOURCE_MODE:-unknown}" \
    --tag "snapshot_version:orbix-v2" \
    >"$restic_output" 2>>"$RUN_LOG"
  status_code=$?
  set -e
  run_finished_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  run_end_epoch=$(date +%s)
  duration_seconds=$((run_end_epoch - run_start_epoch))
  summary_json=$(jq -s 'map(select(.message_type == "summary")) | last // {}' "$restic_output")
  processed_bytes=$(jq -r '.total_bytes_processed // 0' <<<"$summary_json")
  status="ok"
  error_message=""
  if [[ $status_code -ne 0 ]]; then
    status="failed"
    error_message="restic backup failed for full snapshot"
  fi
  cat "$restic_output" >>"$RUN_LOG"
  rm -f "$restic_output"
  catalog_snapshot \
    "$SERVER_ID" \
    "${SOURCE_ROLE:-unknown}" \
    "full" \
    "$repo" \
    "$status" \
    "$paths_json" \
    "$run_started_at" \
    "$run_finished_at" \
    "$source_size_bytes" \
    "$processed_bytes" \
    "$file_count" \
    "$duration_seconds" \
    "$error_message" \
    "orbix-v2" \
    "$manifest_json"
  if [[ $status_code -ne 0 ]]; then
    telegram_send_if_enabled "TELEGRAM_NOTIFY_BACKUP_FAILURE" "Backup failed: ${SERVER_ID} snapshot root devolvio error en restic" "true"
    rm -rf "$staging"
    return "$status_code"
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
