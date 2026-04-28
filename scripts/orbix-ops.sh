#!/usr/bin/env bash
set -Eeuo pipefail

GLOBAL_ENV=${GLOBAL_ENV:-/etc/backup/global.env}
SERVER_DIR=${SERVER_DIR:-/etc/backup/servers.d}

if [[ ! -f "$GLOBAL_ENV" ]]; then
  echo "missing global env: $GLOBAL_ENV" >&2
  exit 1
fi

source "$GLOBAL_ENV"

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

load_server_env() {
  local server_file="$1"
  local env_file="$SERVER_DIR/$server_file"
  if [[ ! -f "$env_file" ]]; then
    echo "missing server env: $env_file" >&2
    exit 1
  fi
  set -a
  source "$env_file"
  set +a
}

remote_ssh_base() {
  printf 'ssh -i %q -p %q -o StrictHostKeyChecking=yes -o BatchMode=yes %q@%q' \
    "${REMOTE_SSH_KEY:?missing REMOTE_SSH_KEY}" \
    "${REMOTE_PORT:-22}" \
    "${REMOTE_USER:?missing REMOTE_USER}" \
    "${REMOTE_HOST:?missing REMOTE_HOST}"
}

run_host_cmd() {
  local command="$1"
  if [[ "${SOURCE_MODE:-local}" == "ssh_pull" ]]; then
    local ssh_cmd
    ssh_cmd=$(remote_ssh_base)
    /bin/bash -lc "${ssh_cmd} $(printf '%q' "$command")"
  else
    /bin/bash -lc "$command"
  fi
}

run_disk_check() {
  local server_file="$1"
  load_server_env "$server_file"
  local threshold="${DISK_THRESHOLD_PCT:-85}"
  local targets="${DISK_ALERT_TARGETS:-/}"
  local line path use_pct critical=0 summary=""

  for path in $targets; do
    line=$(run_host_cmd "df -P '$path' | tail -n 1" || true)
    [[ -n "$line" ]] || continue
    use_pct=$(awk '{print $5}' <<<"$line" | tr -d '%')
    summary+="${SERVER_ID:-$server_file} ${path} ${use_pct}%\n"
    if [[ "${use_pct:-0}" -ge "$threshold" ]]; then
      critical=1
    fi
  done

  printf '%b' "$summary"
  if [[ $critical -eq 1 ]]; then
    telegram_send "Orbix disk alert on ${SERVER_ID:-$server_file}\n$(printf '%b' "$summary")"
    return 2
  fi
}

run_logs() {
  local server_file="$1"
  local source_name="${2:-system}"
  local target="${3:-}"
  local lines="${4:-200}"
  load_server_env "$server_file"

  case "$source_name" in
    system)
      run_host_cmd "journalctl -n ${lines} --no-pager"
      ;;
    docker)
      if [[ -n "$target" ]]; then
        run_host_cmd "docker logs --tail ${lines} ${target} 2>&1"
      else
        run_host_cmd "docker ps --format 'table {{.Names}}\t{{.Image}}\t{{.Status}}'"
      fi
      ;;
    db)
      if [[ -n "$target" ]]; then
        run_host_cmd "docker logs --tail ${lines} ${target} 2>&1"
      else
        run_host_cmd "docker ps --format '{{.Names}} {{.Image}}' | grep -Ei 'mysql|mariadb|mongo|postgres|redis' || true"
      fi
      ;;
    nginx)
      run_host_cmd "tail -n ${lines} /var/log/nginx/error.log /var/log/nginx/access.log 2>/dev/null || docker ps --format '{{.Names}}' | grep -i nginx | head -n1 | xargs -r docker logs --tail ${lines} 2>&1"
      ;;
    apache)
      run_host_cmd "tail -n ${lines} /var/log/apache2/error.log /var/log/apache2/access.log 2>/dev/null || docker ps --format '{{.Names}}' | grep -Ei 'apache|httpd' | head -n1 | xargs -r docker logs --tail ${lines} 2>&1"
      ;;
    kubernetes)
      run_host_cmd "(kubectl get pods -A 2>/dev/null && echo && journalctl -u kubelet -n ${lines} --no-pager 2>/dev/null) || echo 'kubernetes logs unavailable'"
      ;;
    *)
      echo "unsupported log source: $source_name" >&2
      return 1
      ;;
  esac
}

test_telegram() {
  telegram_send "Orbix notification test $(date -u +%Y-%m-%dT%H:%M:%SZ)"
}

usage() {
  cat <<'EOF'
Usage:
  orbix-ops.sh disk-check <server.env>
  orbix-ops.sh logs <server.env> <source> [target] [lines]
  orbix-ops.sh ssh-test <server.env>
  orbix-ops.sh test-telegram
EOF
}

ssh_test() {
  local server_file="$1"
  load_server_env "$server_file"
  if [[ "${SOURCE_MODE:-local}" != "ssh_pull" ]]; then
    echo "server ${SERVER_ID:-$server_file} is not a remote SSH profile" >&2
    return 1
  fi
  if [[ ! -f "${REMOTE_SSH_KEY:?missing REMOTE_SSH_KEY}" ]]; then
    echo "missing ssh key: ${REMOTE_SSH_KEY}" >&2
    return 1
  fi
  ssh -i "$REMOTE_SSH_KEY" \
    -p "${REMOTE_PORT:-22}" \
    -o StrictHostKeyChecking=yes \
    -o BatchMode=yes \
    "${REMOTE_USER:?missing REMOTE_USER}@${REMOTE_HOST:?missing REMOTE_HOST}" \
    'printf "host=%s\nuser=%s\n" "$(hostname)" "$(whoami)"'
}

cmd="${1:-}"
case "$cmd" in
  disk-check)
    run_disk_check "${2:?missing server env filename}"
    ;;
  logs)
    run_logs "${2:?missing server env filename}" "${3:?missing source}" "${4:-}" "${5:-200}"
    ;;
  ssh-test)
    ssh_test "${2:?missing server env filename}"
    ;;
  test-telegram)
    test_telegram
    ;;
  *)
    usage
    exit 1
    ;;
esac
