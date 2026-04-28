#!/usr/bin/env bash
set -Eeuo pipefail

mkdir -p "$BACKUP_STAGING/system" "$BACKUP_STAGING/dokploy-config" "$BACKUP_STAGING/dokploy-db" "$BACKUP_STAGING/docker-volumes" "$BACKUP_STAGING/db-dumps"

copy_if_exists() {
  local src="$1"
  local dst="$2"
  if [[ -e "$src" ]]; then
    rsync -a "$src" "$dst"/
  fi
}

trim() {
  awk '{$1=$1;print}' <<<"$1"
}

resolve_container_env_value() {
  local container="$1"
  local candidate="$2"
  if [[ "$candidate" == env:* ]]; then
    local env_name="${candidate#env:}"
    docker inspect "$container" --format '{{range .Config.Env}}{{println .}}{{end}}' \
      | awk -F= -v key="$env_name" '$1 == key {print substr($0, index($0, "=") + 1)}' \
      | head -n1
  else
    printf '%s' "$candidate"
  fi
}

run_local_postgres_dumps() {
  local raw entry label container user database
  raw="${LOCAL_POSTGRES_DUMPS:-}"
  [[ -n "$raw" ]] || return 0
  IFS=';' read -r -a entries <<<"$raw"
  for entry in "${entries[@]}"; do
    [[ -n "$(trim "$entry")" ]] || continue
    IFS='|' read -r label container user database <<<"$entry"
    docker exec "$container" pg_dump -U "$user" "$database" \
      > "$BACKUP_STAGING/db-dumps/${label}.postgres.sql"
  done
}

run_local_mysql_dumps() {
  local raw entry label container user password database
  raw="${LOCAL_MYSQL_DUMPS:-}"
  [[ -n "$raw" ]] || return 0
  IFS=';' read -r -a entries <<<"$raw"
  for entry in "${entries[@]}"; do
    [[ -n "$(trim "$entry")" ]] || continue
    IFS='|' read -r label container user password database <<<"$entry"
    user=$(resolve_container_env_value "$container" "$user")
    password=$(resolve_container_env_value "$container" "$password")
    database=$(resolve_container_env_value "$container" "$database")
    docker exec -e MYSQL_PWD="$password" "$container" mysqldump -u "$user" "$database" \
      > "$BACKUP_STAGING/db-dumps/${label}.mysql.sql"
  done
}

run_local_mongo_dumps() {
  local raw entry label container database uri
  raw="${LOCAL_MONGO_DUMPS:-}"
  [[ -n "$raw" ]] || return 0
  IFS=';' read -r -a entries <<<"$raw"
  for entry in "${entries[@]}"; do
    [[ -n "$(trim "$entry")" ]] || continue
    IFS='|' read -r label container database uri <<<"$entry"
    database=$(resolve_container_env_value "$container" "$database")
    uri=$(resolve_container_env_value "$container" "$uri")
    if [[ -n "${uri:-}" ]]; then
      docker exec "$container" mongodump --uri "$uri" --archive \
        > "$BACKUP_STAGING/db-dumps/${label}.mongo.archive"
    else
      docker exec "$container" mongodump --db "$database" --archive \
        > "$BACKUP_STAGING/db-dumps/${label}.mongo.archive"
    fi
  done
}

for path in ${HOST_PATHS:-}; do
  copy_if_exists "$path" "$BACKUP_STAGING/system"
done

for path in ${HOST_PATHS_OPTIONAL:-}; do
  copy_if_exists "$path" "$BACKUP_STAGING/system"
done

if [[ -d /etc/dokploy ]]; then
  rsync -a /etc/dokploy/ "$BACKUP_STAGING/dokploy-config/"
fi

POSTGRES_CONTAINER="${DOKPLOY_POSTGRES_CONTAINER:-}"
if [[ -z "$POSTGRES_CONTAINER" ]]; then
  POSTGRES_CONTAINER=$(docker ps --filter name=dokploy-postgres --format '{{.Names}}' | head -n1 || true)
fi

if [[ -n "$POSTGRES_CONTAINER" ]]; then
  docker exec "$POSTGRES_CONTAINER" pg_dump -U "${DOKPLOY_POSTGRES_USER:-dokploy}" "${DOKPLOY_POSTGRES_DB:-dokploy}" \
    > "$BACKUP_STAGING/dokploy-db/dokploy.sql"
fi

run_local_postgres_dumps
run_local_mysql_dumps
run_local_mongo_dumps

if [[ "${SYSTEMD_EXPORT:-false}" == "true" ]]; then
  systemctl list-units --type=service --all --no-pager > "$BACKUP_STAGING/system/systemctl-services.txt"
  ss -tulpn > "$BACKUP_STAGING/system/listening-ports.txt"
  free -h > "$BACKUP_STAGING/system/free.txt"
  df -hT > "$BACKUP_STAGING/system/df.txt"
fi

if [[ "${DOCKER_EXPORT:-false}" == "true" ]]; then
  docker ps -a > "$BACKUP_STAGING/system/docker-ps-a.txt"
  docker volume ls > "$BACKUP_STAGING/system/docker-volume-ls.txt"
fi

if [[ "${UFW_EXPORT:-false}" == "true" ]]; then
  ufw status verbose > "$BACKUP_STAGING/system/ufw-status.txt" 2>&1 || true
fi

for vol in ${DOCKER_VOLUMES:-}; do
  mountpoint=$(docker volume inspect "$vol" --format '{{.Mountpoint}}' 2>/dev/null || true)
  if [[ -n "$mountpoint" && -d "$mountpoint" ]]; then
    set +e
    tar --warning=no-file-changed -C "$mountpoint" -czf "$BACKUP_STAGING/docker-volumes/${vol}.tar.gz" .
    tar_status=$?
    set -e
    if [[ $tar_status -gt 1 ]]; then
      exit "$tar_status"
    fi
  fi
done
