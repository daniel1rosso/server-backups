#!/usr/bin/env bash
set -Eeuo pipefail

mkdir -p "$BACKUP_STAGING/system" "$BACKUP_STAGING/db-dumps" "$BACKUP_STAGING/docker-volumes" "$BACKUP_STAGING/compose-projects" "$BACKUP_STAGING/k8s-manifests"

SSH_OPTS=(-i "${REMOTE_SSH_KEY:?missing REMOTE_SSH_KEY}" -p "${REMOTE_PORT:-22}" -o StrictHostKeyChecking=yes)
REMOTE="${REMOTE_USER:?missing REMOTE_USER}@${REMOTE_HOST:?missing REMOTE_HOST}"

trim() {
  awk '{$1=$1;print}' <<<"$1"
}

resolve_remote_container_env_value() {
  local container="$1"
  local candidate="$2"
  if [[ "$candidate" == env:* ]]; then
    local env_name="${candidate#env:}"
    ssh "${SSH_OPTS[@]}" "$REMOTE" \
      "docker inspect '$container' --format '{{range .Config.Env}}{{println .}}{{end}}' | awk -F= -v key='$env_name' '\$1 == key {print substr(\$0, index(\$0, \"=\") + 1)}' | head -n1"
  else
    printf '%s' "$candidate"
  fi
}

run_remote_postgres_dumps() {
  local raw entry label container user database
  raw="${REMOTE_POSTGRES_DUMPS:-}"
  [[ -n "$raw" ]] || return 0
  IFS=';' read -r -a entries <<<"$raw"
  for entry in "${entries[@]}"; do
    [[ -n "$(trim "$entry")" ]] || continue
    IFS='|' read -r label container user database <<<"$entry"
    ssh "${SSH_OPTS[@]}" "$REMOTE" "docker exec '$container' pg_dump -U '$user' '$database'" \
      > "$BACKUP_STAGING/db-dumps/${label}.postgres.sql"
  done
}

run_remote_mysql_dumps() {
  local raw entry label container user password database
  raw="${REMOTE_MYSQL_DUMPS:-}"
  [[ -n "$raw" ]] || return 0
  IFS=';' read -r -a entries <<<"$raw"
  for entry in "${entries[@]}"; do
    [[ -n "$(trim "$entry")" ]] || continue
    IFS='|' read -r label container user password database <<<"$entry"
    user=$(resolve_remote_container_env_value "$container" "$user")
    password=$(resolve_remote_container_env_value "$container" "$password")
    database=$(resolve_remote_container_env_value "$container" "$database")
    ssh "${SSH_OPTS[@]}" "$REMOTE" "docker exec -e MYSQL_PWD='$password' '$container' mysqldump -u '$user' '$database'" \
      > "$BACKUP_STAGING/db-dumps/${label}.mysql.sql"
  done
}

run_remote_mongo_dumps() {
  local raw entry label container database uri
  raw="${REMOTE_MONGO_DUMPS:-}"
  [[ -n "$raw" ]] || return 0
  IFS=';' read -r -a entries <<<"$raw"
  for entry in "${entries[@]}"; do
    [[ -n "$(trim "$entry")" ]] || continue
    IFS='|' read -r label container database uri <<<"$entry"
    database=$(resolve_remote_container_env_value "$container" "$database")
    uri=$(resolve_remote_container_env_value "$container" "$uri")
    if [[ -n "${uri:-}" ]]; then
      ssh "${SSH_OPTS[@]}" "$REMOTE" "docker exec '$container' mongodump --uri '$uri' --archive" \
        > "$BACKUP_STAGING/db-dumps/${label}.mongo.archive"
    else
      ssh "${SSH_OPTS[@]}" "$REMOTE" "docker exec '$container' mongodump --db '$database' --archive" \
        > "$BACKUP_STAGING/db-dumps/${label}.mongo.archive"
    fi
  done
}

run_remote_system_exports() {
  if [[ "${REMOTE_SYSTEM_EXPORT:-false}" != "true" ]]; then
    return 0
  fi
  ssh "${SSH_OPTS[@]}" "$REMOTE" "uname -a" > "$BACKUP_STAGING/system/uname.txt"
  ssh "${SSH_OPTS[@]}" "$REMOTE" "hostname" > "$BACKUP_STAGING/system/hostname.txt"
  ssh "${SSH_OPTS[@]}" "$REMOTE" "free -h" > "$BACKUP_STAGING/system/free.txt"
  ssh "${SSH_OPTS[@]}" "$REMOTE" "df -hT" > "$BACKUP_STAGING/system/df.txt"
  ssh "${SSH_OPTS[@]}" "$REMOTE" "ss -tulpn" > "$BACKUP_STAGING/system/listening-ports.txt"
  ssh "${SSH_OPTS[@]}" "$REMOTE" "systemctl list-units --type=service --all --no-pager" > "$BACKUP_STAGING/system/systemctl-services.txt"
  ssh "${SSH_OPTS[@]}" "$REMOTE" "ufw status verbose" > "$BACKUP_STAGING/system/ufw-status.txt" 2>&1 || true
}

run_remote_docker_exports() {
  if [[ "${REMOTE_DOCKER_EXPORT:-false}" != "true" ]]; then
    return 0
  fi
  ssh "${SSH_OPTS[@]}" "$REMOTE" "docker ps -a" > "$BACKUP_STAGING/system/docker-ps-a.txt"
  ssh "${SSH_OPTS[@]}" "$REMOTE" "docker volume ls" > "$BACKUP_STAGING/system/docker-volume-ls.txt"
  ssh "${SSH_OPTS[@]}" "$REMOTE" "docker network ls" > "$BACKUP_STAGING/system/docker-network-ls.txt"
}

run_remote_volume_archives() {
  local raw entry mountpoint
  raw="${REMOTE_DOCKER_VOLUMES:-}"
  [[ -n "$raw" ]] || return 0
  IFS=' ' read -r -a entries <<<"$raw"
  for entry in "${entries[@]}"; do
    [[ -n "$(trim "$entry")" ]] || continue
    mountpoint=$(ssh "${SSH_OPTS[@]}" "$REMOTE" "docker volume inspect '$entry' --format '{{.Mountpoint}}'" 2>/dev/null || true)
    if [[ -n "$mountpoint" ]]; then
      ssh "${SSH_OPTS[@]}" "$REMOTE" "tar --warning=no-file-changed -C '$mountpoint' -czf - ." \
        > "$BACKUP_STAGING/docker-volumes/${entry}.tar.gz" || true
    fi
  done
}

copy_remote_project_entries() {
  local raw="$1"
  local root="$2"
  local entry label source
  [[ -n "$raw" ]] || return 0
  IFS=';' read -r -a entries <<<"$raw"
  for entry in "${entries[@]}"; do
    [[ -n "$(trim "$entry")" ]] || continue
    if [[ "$entry" == *"|"* ]]; then
      IFS='|' read -r label source <<<"$entry"
    else
      source="$entry"
      label=$(basename "${source%/}")
    fi
    mkdir -p "$BACKUP_STAGING/$root/$label"
    set +e
    rsync -az -e "ssh ${SSH_OPTS[*]}" "${REMOTE}:${source%/}/" "$BACKUP_STAGING/$root/$label"/
    rsync_status=$?
    set -e
    if [[ $rsync_status -ne 0 ]]; then
      set +e
      rsync -az -e "ssh ${SSH_OPTS[*]}" "${REMOTE}:${source}" "$BACKUP_STAGING/$root/$label"/
      rsync_status=$?
      set -e
      if [[ $rsync_status -ne 0 && $rsync_status -ne 23 ]]; then
        exit "$rsync_status"
      fi
    fi
  done
}

for path in ${REMOTE_PATHS:-}; do
  set +e
  rsync -az -e "ssh ${SSH_OPTS[*]}" "${REMOTE}:${path}" "$BACKUP_STAGING/system/"
  rsync_status=$?
  set -e
  if [[ $rsync_status -ne 0 && $rsync_status -ne 23 ]]; then
    exit "$rsync_status"
  fi
done

for path in ${REMOTE_PATHS_OPTIONAL:-}; do
  set +e
  rsync -az -e "ssh ${SSH_OPTS[*]}" "${REMOTE}:${path}" "$BACKUP_STAGING/system/"
  rsync_status=$?
  set -e
  if [[ $rsync_status -ne 0 && $rsync_status -ne 23 ]]; then
    exit "$rsync_status"
  fi
done

if [[ -n "${REMOTE_PRE_DUMP_COMMANDS:-}" ]]; then
  ssh "${SSH_OPTS[@]}" "$REMOTE" "$REMOTE_PRE_DUMP_COMMANDS"
fi

run_remote_system_exports
run_remote_docker_exports
run_remote_postgres_dumps
run_remote_mysql_dumps
run_remote_mongo_dumps
run_remote_volume_archives
copy_remote_project_entries "${COMPOSE_PROJECT_PATHS:-}" "compose-projects"
copy_remote_project_entries "${K8S_MANIFEST_PATHS:-}" "k8s-manifests"
