#!/usr/bin/env bash
set -Eeuo pipefail

GLOBAL_ENV=${GLOBAL_ENV:-/etc/backup/global.env}
SERVER_DIR=${SERVER_DIR:-/etc/backup/servers.d}

if [[ ! -f "$GLOBAL_ENV" ]]; then
  echo "missing global env: $GLOBAL_ENV" >&2
  exit 1
fi

source "$GLOBAL_ENV"

CATALOG_DB="$STATE_DIR/catalog/backups.sqlite3"
WORK_ROOT="${TMP_DIR:-/var/tmp/backup-platform}/restore-work"

usage() {
  cat <<'EOF'
Usage:
  backup-restore-helper.sh list
  backup-restore-helper.sh snapshots <server_id>
  backup-restore-helper.sh ls <server_id> <snapshot_id> [snapshot_subpath]
  backup-restore-helper.sh verify <server_id> <snapshot_or_ref> <target_dir> [--include <path> ...] [--strategy <staging|direct>] [--scope <full|partial>]
  backup-restore-helper.sh restore <server_id> <snapshot_or_ref> <target_dir> [--include <path> ...] [--strategy <staging|direct>] [--scope <full|partial>]
EOF
}

log() {
  printf '%s %s\n' "$(date '+%F %T')" "$*"
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

trim() {
  awk '{$1=$1;print}' <<<"$1"
}

load_server_env() {
  local server_id="$1"
  SERVER_ENV_FILE="$SERVER_DIR/${server_id}.env"
  if [[ ! -f "$SERVER_ENV_FILE" ]]; then
    echo "missing server env: $SERVER_ENV_FILE" >&2
    exit 1
  fi
  set -a
  source "$SERVER_ENV_FILE"
  set +a
}

remote_ssh_base() {
  printf 'ssh -i %q -p %q -o StrictHostKeyChecking=yes -o BatchMode=yes %q@%q' \
    "${REMOTE_SSH_KEY:?missing REMOTE_SSH_KEY}" \
    "${REMOTE_PORT:-22}" \
    "${REMOTE_USER:?missing REMOTE_USER}" \
    "${REMOTE_HOST:?missing REMOTE_HOST}"
}

setup_repo() {
  local server_id="$1"
  load_server_env "$server_id"
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
  RESTORE_STRATEGY="staging"
  RESTORE_SCOPE="full"
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --include)
        [[ $# -ge 2 ]] || { echo "missing value for --include" >&2; exit 1; }
        RESTORE_INCLUDE_ARGS+=("--include" "$2")
        shift 2
        ;;
      --strategy)
        [[ $# -ge 2 ]] || { echo "missing value for --strategy" >&2; exit 1; }
        RESTORE_STRATEGY="$2"
        shift 2
        ;;
      --scope)
        [[ $# -ge 2 ]] || { echo "missing value for --scope" >&2; exit 1; }
        RESTORE_SCOPE="$2"
        shift 2
        ;;
      --notes)
        [[ $# -ge 2 ]] || { echo "missing value for --notes" >&2; exit 1; }
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
  echo "strategy=$RESTORE_STRATEGY"
  echo "scope=$RESTORE_SCOPE"
  if [[ ${#RESTORE_INCLUDE_ARGS[@]} -gt 0 ]]; then
    printf 'includes='
    printf '%s ' "${RESTORE_INCLUDE_ARGS[@]}"
    printf '\n'
  fi
}

run_target_cmd() {
  local command="$1"
  if [[ "${SOURCE_MODE:-local}" == "ssh_pull" ]]; then
    local ssh_cmd
    ssh_cmd=$(remote_ssh_base)
    /bin/bash -lc "${ssh_cmd} $(printf '%q' "$command")"
  else
    /bin/bash -lc "$command"
  fi
}

resolve_target_container_env_value() {
  local container="$1"
  local candidate="$2"
  if [[ "$candidate" == env:* ]]; then
    local env_name="${candidate#env:}"
    run_target_cmd "sudo docker inspect $(printf '%q' "$container") --format '{{range .Config.Env}}{{println .}}{{end}}' | awk -F= -v key=$(printf '%q' "$env_name") '\$1 == key {print substr(\$0, index(\$0, \"=\") + 1)}' | head -n1"
  else
    printf '%s' "$candidate"
  fi
}

rsync_to_target() {
  local source_path="$1"
  local target_path="$2"
  if [[ "${SOURCE_MODE:-local}" == "ssh_pull" ]]; then
    rsync -az -e "ssh -i ${REMOTE_SSH_KEY} -p ${REMOTE_PORT:-22} -o StrictHostKeyChecking=yes" "$source_path" "${REMOTE_USER}@${REMOTE_HOST}:${target_path}"
  else
    rsync -a "$source_path" "$target_path"
  fi
}

copy_file_to_target() {
  local source_path="$1"
  local target_path="$2"
  local parent
  parent=$(dirname "$target_path")
  run_target_cmd "sudo mkdir -p $(printf '%q' "$parent")"
  if [[ "${SOURCE_MODE:-local}" == "ssh_pull" ]]; then
    rsync -az -e "ssh -i ${REMOTE_SSH_KEY} -p ${REMOTE_PORT:-22} -o StrictHostKeyChecking=yes" "$source_path" "${REMOTE_USER}@${REMOTE_HOST}:${target_path}"
  else
    cp -a "$source_path" "$target_path"
  fi
}

restore_workspace() {
  local snapshot_ref="$1"
  local workspace="$2"
  mkdir -p "$workspace"
  restic_cmd restore "$snapshot_ref" --target "$workspace" "${RESTORE_INCLUDE_ARGS[@]}"
}

find_snapshot_root() {
  local workspace="$1"
  local manifest_path
  manifest_path=$(find "$workspace" -name snapshot-manifest.json -print | head -n1 || true)
  if [[ -n "$manifest_path" ]]; then
    dirname "$manifest_path"
  else
    echo "$workspace"
  fi
}

manifest_field() {
  local manifest_path="$1"
  local jq_expr="$2"
  if [[ ! -f "$manifest_path" ]]; then
    return 1
  fi
  jq -r "$jq_expr" "$manifest_path"
}

manifest_array() {
  local manifest_path="$1"
  local jq_expr="$2"
  if [[ ! -f "$manifest_path" ]]; then
    return 0
  fi
  jq -r "$jq_expr | .[]?" "$manifest_path"
}

warn_legacy_snapshot() {
  log "legacy snapshot detected: no snapshot-manifest.json found"
  log "falling back to plain restore output under workspace/target only"
}

package_installed() {
  local package_name="$1"
  run_target_cmd "dpkg-query -W -f='\${Status}' $(printf '%q' "$package_name") 2>/dev/null | grep -q 'install ok installed'"
}

ensure_target_packages() {
  local manifest_path="$1"
  [[ -f "$manifest_path" ]] || return 0
  if ! run_target_cmd "command -v apt-get >/dev/null 2>&1"; then
    log "apt-get not available on target; skipping package installation"
    return 0
  fi
  local packages=()
  while IFS= read -r package_name; do
    [[ -n "$package_name" ]] && packages+=("$package_name")
  done < <(manifest_array "$manifest_path" '.restore.required_apt_packages')
  local missing=()
  local package_name
  for package_name in "${packages[@]}"; do
    if ! package_installed "$package_name"; then
      missing+=("$package_name")
    fi
  done
  if [[ ${#missing[@]} -gt 0 ]]; then
    log "installing missing packages: ${missing[*]}"
    run_target_cmd "sudo apt-get update && sudo apt-get install -y ${missing[*]}"
  fi
}

restore_system_paths() {
  local snapshot_root="$1"
  local manifest_path="$2"
  [[ -f "$manifest_path" ]] || return 0
  jq -c '.artifacts.system_paths[]?' "$manifest_path" | while IFS= read -r item; do
    local source snapshot_path target_source source_item parent target_dir
    source=$(jq -r '.source' <<<"$item")
    snapshot_path=$(jq -r '.snapshot_path' <<<"$item")
    source_item="$snapshot_root/$snapshot_path"
    [[ -e "$source_item" ]] || continue
    parent=$(dirname "$source")
    run_target_cmd "sudo mkdir -p $(printf '%q' "$parent")"
    if [[ -d "$source_item" ]]; then
      run_target_cmd "sudo mkdir -p $(printf '%q' "$source")"
      if [[ "${SOURCE_MODE:-local}" == "ssh_pull" ]]; then
        rsync -az --delete -e "ssh -i ${REMOTE_SSH_KEY} -p ${REMOTE_PORT:-22} -o StrictHostKeyChecking=yes" "$source_item"/ "${REMOTE_USER}@${REMOTE_HOST}:${source}/"
      else
        rsync -a --delete "$source_item"/ "$source"/
      fi
    else
      copy_file_to_target "$source_item" "$source"
    fi
    log "restored system path $source"
  done
}

restore_compose_projects() {
  local snapshot_root="$1"
  local manifest_path="$2"
  [[ -f "$manifest_path" ]] || return 0
  jq -c '.artifacts.compose_projects[]?' "$manifest_path" | while IFS= read -r item; do
    local label source snapshot_path source_item workdir
    label=$(jq -r '.label' <<<"$item")
    source=$(jq -r '.source' <<<"$item")
    snapshot_path=$(jq -r '.snapshot_path' <<<"$item")
    source_item="$snapshot_root/$snapshot_path"
    [[ -e "$source_item" ]] || continue
    if [[ -d "$source_item" ]]; then
      run_target_cmd "sudo mkdir -p $(printf '%q' "$source")"
      if [[ "${SOURCE_MODE:-local}" == "ssh_pull" ]]; then
        rsync -az --delete -e "ssh -i ${REMOTE_SSH_KEY} -p ${REMOTE_PORT:-22} -o StrictHostKeyChecking=yes" "$source_item"/ "${REMOTE_USER}@${REMOTE_HOST}:${source}/"
      else
        rsync -a --delete "$source_item"/ "$source"/
      fi
      workdir="$source"
    else
      copy_file_to_target "$source_item" "$source"
      workdir=$(dirname "$source")
    fi
    log "restored compose project $label to $source"
    run_target_cmd "cd $(printf '%q' "$workdir") && sudo docker compose up -d"
  done
}

restore_k8s_manifests() {
  local snapshot_root="$1"
  local manifest_path="$2"
  [[ -f "$manifest_path" ]] || return 0
  jq -c '.artifacts.k8s_manifests[]?' "$manifest_path" | while IFS= read -r item; do
    local label source snapshot_path source_item apply_path
    label=$(jq -r '.label' <<<"$item")
    source=$(jq -r '.source' <<<"$item")
    snapshot_path=$(jq -r '.snapshot_path' <<<"$item")
    source_item="$snapshot_root/$snapshot_path"
    [[ -e "$source_item" ]] || continue
    if [[ -d "$source_item" ]]; then
      run_target_cmd "sudo mkdir -p $(printf '%q' "$source")"
      if [[ "${SOURCE_MODE:-local}" == "ssh_pull" ]]; then
        rsync -az --delete -e "ssh -i ${REMOTE_SSH_KEY} -p ${REMOTE_PORT:-22} -o StrictHostKeyChecking=yes" "$source_item"/ "${REMOTE_USER}@${REMOTE_HOST}:${source}/"
      else
        rsync -a --delete "$source_item"/ "$source"/
      fi
      apply_path="$source"
    else
      copy_file_to_target "$source_item" "$source"
      apply_path="$source"
    fi
    log "restored kubernetes manifest $label to $source"
    run_target_cmd "sudo kubectl apply -f $(printf '%q' "$apply_path")"
  done
}

restore_docker_volumes() {
  local snapshot_root="$1"
  local manifest_path="$2"
  [[ -f "$manifest_path" ]] || return 0
  jq -c '.artifacts.docker_volumes[]?' "$manifest_path" | while IFS= read -r item; do
    local volume_name snapshot_path archive_path mountpoint remote_archive
    volume_name=$(jq -r '.name' <<<"$item")
    snapshot_path=$(jq -r '.snapshot_path' <<<"$item")
    archive_path="$snapshot_root/$snapshot_path"
    [[ -f "$archive_path" ]] || continue
    run_target_cmd "sudo docker volume inspect $(printf '%q' "$volume_name") >/dev/null 2>&1 || sudo docker volume create $(printf '%q' "$volume_name") >/dev/null"
    mountpoint=$(run_target_cmd "sudo docker volume inspect $(printf '%q' "$volume_name") --format '{{.Mountpoint}}'" | tr -d '\r')
    if [[ "${SOURCE_MODE:-local}" == "ssh_pull" ]]; then
      remote_archive="/tmp/orbix-${volume_name}.tar.gz"
      rsync -az -e "ssh -i ${REMOTE_SSH_KEY} -p ${REMOTE_PORT:-22} -o StrictHostKeyChecking=yes" "$archive_path" "${REMOTE_USER}@${REMOTE_HOST}:${remote_archive}"
      run_target_cmd "sudo mkdir -p $(printf '%q' "$mountpoint") && sudo tar -xzf $(printf '%q' "$remote_archive") -C $(printf '%q' "$mountpoint") && rm -f $(printf '%q' "$remote_archive")"
    else
      run_target_cmd "sudo mkdir -p $(printf '%q' "$mountpoint")"
      tar -xzf "$archive_path" -C "$mountpoint"
    fi
    log "restored docker volume $volume_name"
  done
}

restore_special_dokploy() {
  local snapshot_root="$1"
  local manifest_path="$2"
  local dokploy_path dokploy_dump
  [[ -f "$manifest_path" ]] || return 0
  dokploy_path=$(manifest_field "$manifest_path" '.artifacts.dokploy_config // empty' || true)
  dokploy_dump=$(manifest_field "$manifest_path" '.artifacts.dokploy_db_dump // empty' || true)
  if [[ -n "$dokploy_path" && -d "$snapshot_root/$dokploy_path" ]]; then
    run_target_cmd "sudo mkdir -p /etc/dokploy"
    if [[ "${SOURCE_MODE:-local}" == "ssh_pull" ]]; then
      rsync -az --delete -e "ssh -i ${REMOTE_SSH_KEY} -p ${REMOTE_PORT:-22} -o StrictHostKeyChecking=yes" "$snapshot_root/$dokploy_path"/ "${REMOTE_USER}@${REMOTE_HOST}:/etc/dokploy/"
    else
      rsync -a --delete "$snapshot_root/$dokploy_path"/ /etc/dokploy/
    fi
    log "restored dokploy config to /etc/dokploy"
  fi
  if [[ -n "$dokploy_dump" && -f "$snapshot_root/$dokploy_dump" && -n "${DOKPLOY_POSTGRES_CONTAINER:-}" ]]; then
    if [[ "${SOURCE_MODE:-local}" == "ssh_pull" ]]; then
      rsync -az -e "ssh -i ${REMOTE_SSH_KEY} -p ${REMOTE_PORT:-22} -o StrictHostKeyChecking=yes" "$snapshot_root/$dokploy_dump" "${REMOTE_USER}@${REMOTE_HOST}:/tmp/orbix-dokploy.sql"
      run_target_cmd "sudo docker exec -i $(printf '%q' "$DOKPLOY_POSTGRES_CONTAINER") psql -U $(printf '%q' "${DOKPLOY_POSTGRES_USER:-dokploy}") $(printf '%q' "${DOKPLOY_POSTGRES_DB:-dokploy}") < /tmp/orbix-dokploy.sql && rm -f /tmp/orbix-dokploy.sql"
    else
      docker exec -i "$DOKPLOY_POSTGRES_CONTAINER" psql -U "${DOKPLOY_POSTGRES_USER:-dokploy}" "${DOKPLOY_POSTGRES_DB:-dokploy}" < "$snapshot_root/$dokploy_dump"
    fi
    log "restored dokploy database dump"
  fi
}

restore_declared_database_dumps() {
  local snapshot_root="$1"
  local raw entry label container user password database uri dump_path remote_tmp
  if [[ -n "${LOCAL_POSTGRES_DUMPS:-}${REMOTE_POSTGRES_DUMPS:-}" ]]; then
    raw="${LOCAL_POSTGRES_DUMPS:-${REMOTE_POSTGRES_DUMPS:-}}"
    IFS=';' read -r -a entries <<<"$raw"
    for entry in "${entries[@]}"; do
      [[ -n "$(trim "$entry")" ]] || continue
      IFS='|' read -r label container user database <<<"$entry"
      user=$(resolve_target_container_env_value "$container" "$user")
      database=$(resolve_target_container_env_value "$container" "$database")
      dump_path="$snapshot_root/db-dumps/${label}.postgres.sql"
      [[ -f "$dump_path" ]] || continue
      if [[ "${SOURCE_MODE:-local}" == "ssh_pull" ]]; then
        remote_tmp="/tmp/${label}.postgres.sql"
        rsync -az -e "ssh -i ${REMOTE_SSH_KEY} -p ${REMOTE_PORT:-22} -o StrictHostKeyChecking=yes" "$dump_path" "${REMOTE_USER}@${REMOTE_HOST}:${remote_tmp}"
        run_target_cmd "sudo docker exec -i $(printf '%q' "$container") psql -U $(printf '%q' "$user") $(printf '%q' "$database") < $(printf '%q' "$remote_tmp") && rm -f $(printf '%q' "$remote_tmp")"
      else
        docker exec -i "$container" psql -U "$user" "$database" < "$dump_path"
      fi
      log "restored postgres dump $label"
    done
  fi
  if [[ -n "${LOCAL_MYSQL_DUMPS:-}${REMOTE_MYSQL_DUMPS:-}" ]]; then
    raw="${LOCAL_MYSQL_DUMPS:-${REMOTE_MYSQL_DUMPS:-}}"
    IFS=';' read -r -a entries <<<"$raw"
    for entry in "${entries[@]}"; do
      [[ -n "$(trim "$entry")" ]] || continue
      IFS='|' read -r label container user password database <<<"$entry"
      user=$(resolve_target_container_env_value "$container" "$user")
      password=$(resolve_target_container_env_value "$container" "$password")
      database=$(resolve_target_container_env_value "$container" "$database")
      dump_path="$snapshot_root/db-dumps/${label}.mysql.sql"
      [[ -f "$dump_path" ]] || continue
      if [[ "${SOURCE_MODE:-local}" == "ssh_pull" ]]; then
        remote_tmp="/tmp/${label}.mysql.sql"
        rsync -az -e "ssh -i ${REMOTE_SSH_KEY} -p ${REMOTE_PORT:-22} -o StrictHostKeyChecking=yes" "$dump_path" "${REMOTE_USER}@${REMOTE_HOST}:${remote_tmp}"
        run_target_cmd "sudo docker exec -e MYSQL_PWD=$(printf '%q' "$password") -i $(printf '%q' "$container") mysql -u $(printf '%q' "$user") $(printf '%q' "$database") < $(printf '%q' "$remote_tmp") && rm -f $(printf '%q' "$remote_tmp")"
      else
        docker exec -e MYSQL_PWD="$password" -i "$container" mysql -u "$user" "$database" < "$dump_path"
      fi
      log "restored mysql dump $label"
    done
  fi
  if [[ -n "${LOCAL_MONGO_DUMPS:-}${REMOTE_MONGO_DUMPS:-}" ]]; then
    raw="${LOCAL_MONGO_DUMPS:-${REMOTE_MONGO_DUMPS:-}}"
    IFS=';' read -r -a entries <<<"$raw"
    for entry in "${entries[@]}"; do
      [[ -n "$(trim "$entry")" ]] || continue
      IFS='|' read -r label container database uri <<<"$entry"
      database=$(resolve_target_container_env_value "$container" "$database")
      uri=$(resolve_target_container_env_value "$container" "$uri")
      dump_path="$snapshot_root/db-dumps/${label}.mongo.archive"
      [[ -f "$dump_path" ]] || continue
      if [[ "${SOURCE_MODE:-local}" == "ssh_pull" ]]; then
        remote_tmp="/tmp/${label}.mongo.archive"
        rsync -az -e "ssh -i ${REMOTE_SSH_KEY} -p ${REMOTE_PORT:-22} -o StrictHostKeyChecking=yes" "$dump_path" "${REMOTE_USER}@${REMOTE_HOST}:${remote_tmp}"
        if [[ -n "${uri:-}" ]]; then
          run_target_cmd "sudo docker exec -i $(printf '%q' "$container") mongorestore --uri $(printf '%q' "$uri") --archive < $(printf '%q' "$remote_tmp") && rm -f $(printf '%q' "$remote_tmp")"
        else
          run_target_cmd "sudo docker exec -i $(printf '%q' "$container") mongorestore --db $(printf '%q' "$database") --archive < $(printf '%q' "$remote_tmp") && rm -f $(printf '%q' "$remote_tmp")"
        fi
      else
        if [[ -n "${uri:-}" ]]; then
          docker exec -i "$container" mongorestore --uri "$uri" --archive < "$dump_path"
        else
          docker exec -i "$container" mongorestore --db "$database" --archive < "$dump_path"
        fi
      fi
      log "restored mongo dump $label"
    done
  fi
}

start_systemd_services() {
  local manifest_path="$1"
  [[ -f "$manifest_path" ]] || return 0
  local service_name
  while IFS= read -r service_name; do
    [[ -n "$service_name" ]] || continue
    run_target_cmd "sudo systemctl enable --now $(printf '%q' "$service_name")"
    log "started systemd service $service_name"
  done < <(manifest_array "$manifest_path" '.restore.systemd_services')
}

verify_restore_state() {
  local manifest_path="$1"
  [[ -f "$manifest_path" ]] || return 0
  local service_name
  while IFS= read -r service_name; do
    [[ -n "$service_name" ]] || continue
    run_target_cmd "systemctl is-active $(printf '%q' "$service_name") >/dev/null"
    log "verified systemd service $service_name"
  done < <(manifest_array "$manifest_path" '.restore.systemd_services')
}

plain_restore() {
  local snapshot_ref="$1"
  local target_dir="$2"
  mkdir -p "$target_dir"
  restic_cmd restore "$snapshot_ref" --target "$target_dir" "${RESTORE_INCLUDE_ARGS[@]}"
}

orchestrated_restore() {
  local server_id="$1"
  local snapshot_ref="$2"
  local target_dir="$3"
  local workdir snapshot_root manifest_path

  mkdir -p "$WORK_ROOT"
  workdir="$WORK_ROOT/${server_id}-$(date +%s)"
  mkdir -p "$workdir"
  log "restore workspace: $workdir"
  restore_workspace "$snapshot_ref" "$workdir"
  snapshot_root=$(find_snapshot_root "$workdir")
  manifest_path="$snapshot_root/snapshot-manifest.json"

  if [[ ! -f "$manifest_path" ]]; then
    warn_legacy_snapshot
    mkdir -p "$target_dir"
    rsync -a "$workdir"/ "$target_dir"/
    log "legacy snapshot copied to $target_dir for manual continuation"
    return 0
  fi

  ensure_target_packages "$manifest_path"
  restore_system_paths "$snapshot_root" "$manifest_path"
  restore_special_dokploy "$snapshot_root" "$manifest_path"
  restore_docker_volumes "$snapshot_root" "$manifest_path"
  restore_compose_projects "$snapshot_root" "$manifest_path"
  restore_k8s_manifests "$snapshot_root" "$manifest_path"
  restore_declared_database_dumps "$snapshot_root"
  start_systemd_services "$manifest_path"
  verify_restore_state "$manifest_path"
  mkdir -p "$target_dir"
  cp -a "$manifest_path" "$target_dir/restore-report-manifest.json"
  log "autonomous restore completed"
}

cmd="${1:-}"
case "$cmd" in
  list)
    sqlite3 -header -column "$CATALOG_DB" \
      "select server_id, source_role, group_name, restic_short_id, created_at, snapshot_version from runs order by id desc;"
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
    if [[ "$RESTORE_STRATEGY" == "direct" && "$RESTORE_SCOPE" == "full" && ${#RESTORE_INCLUDE_ARGS[@]} -eq 0 ]]; then
      orchestrated_restore "$server_id" "$snapshot_ref" "$target_dir"
    else
      plain_restore "$snapshot_ref" "$target_dir"
    fi
    ;;
  *)
    usage
    exit 1
    ;;
esac
