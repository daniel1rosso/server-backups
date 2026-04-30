#!/usr/bin/env bash
set -Eeuo pipefail

GLOBAL_ENV=${GLOBAL_ENV:-/etc/backup/global.env}
SERVER_DIR=${SERVER_DIR:-/etc/backup/servers.d}

if [[ ! -f "$GLOBAL_ENV" ]]; then
  echo "missing global env: $GLOBAL_ENV" >&2
  exit 1
fi

source "$GLOBAL_ENV"

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
  local state_dir="${STATE_DIR:-/var/lib/backup}/disk-check"
  local state_file="${state_dir}/${SERVER_ID:-$server_file}.state"
  local previous_state="unknown" current_state="ok"

  mkdir -p "$state_dir"
  if [[ -f "$state_file" ]]; then
    previous_state=$(<"$state_file")
  fi

  for path in $targets; do
    line=$(run_host_cmd "df -P '$path' | tail -n 1" || true)
    [[ -n "$line" ]] || continue
    use_pct=$(awk '{print $5}' <<<"$line" | tr -d '%')
    summary+="${SERVER_ID:-$server_file} ${path} ${use_pct}%\n"
    if [[ "${use_pct:-0}" -ge "$threshold" ]]; then
      critical=1
    fi
  done

  if [[ $critical -eq 1 ]]; then
    current_state="critical"
  fi
  printf '%s\n' "$current_state" >"$state_file"
  printf '%b' "$summary"
  if [[ $critical -eq 1 ]]; then
    if [[ "$previous_state" != "critical" ]]; then
      telegram_send_if_enabled "TELEGRAM_NOTIFY_DISK_ALERT" "Orbix disk alert on ${SERVER_ID:-$server_file}\nthreshold=${threshold}%\n$(printf '%b' "$summary")" "true"
    fi
    return 2
  fi
  if [[ "$previous_state" == "critical" ]]; then
    telegram_send_if_enabled "TELEGRAM_NOTIFY_DISK_RECOVERY" "Orbix disk recovered on ${SERVER_ID:-$server_file}\nthreshold=${threshold}%\n$(printf '%b' "$summary")" "false"
  fi
}

write_metric_state() {
  local state_dir="$1"
  local metric_name="$2"
  local current_state="$3"
  mkdir -p "$state_dir"
  printf '%s\n' "$current_state" >"${state_dir}/${metric_name}.state"
}

read_metric_state() {
  local state_dir="$1"
  local metric_name="$2"
  local state_file="${state_dir}/${metric_name}.state"
  if [[ -f "$state_file" ]]; then
    cat "$state_file"
    return 0
  fi
  printf 'unknown\n'
}

normalize_token_list() {
  tr ',\n' '  ' <<<"${1:-}" | xargs -n1 2>/dev/null || true
}

matches_token_filter() {
  local candidate="$1"
  shift || true
  if [[ $# -eq 0 ]]; then
    return 0
  fi
  local token
  for token in "$@"; do
    [[ -z "$token" ]] && continue
    if [[ "$candidate" == "$token" || "$candidate" == *"$token"* ]]; then
      return 0
    fi
  done
  return 1
}

write_state_entries() {
  local state_file="$1"
  shift || true
  mkdir -p "$(dirname "$state_file")"
  if [[ $# -eq 0 ]]; then
    : >"$state_file"
    return 0
  fi
  printf '%s\n' "$@" | sort >"$state_file"
}

state_value_for_key() {
  local state_file="$1"
  local key="$2"
  [[ -f "$state_file" ]] || return 1
  awk -F'|' -v lookup="$key" '$1 == lookup {print $2; exit}' "$state_file"
}

state_detail_for_key() {
  local state_file="$1"
  local key="$2"
  [[ -f "$state_file" ]] || return 1
  awk -F'|' -v lookup="$key" '$1 == lookup {print $3; exit}' "$state_file"
}

state_keys() {
  local state_file="$1"
  [[ -f "$state_file" ]] || return 0
  awk -F'|' '{print $1}' "$state_file"
}

run_resource_check() {
  local server_file="$1"
  load_server_env "$server_file"
  local cpu_threshold="${CPU_THRESHOLD_PCT:-90}"
  local ram_threshold="${RAM_THRESHOLD_PCT:-90}"
  local state_dir="${STATE_DIR:-/var/lib/backup}/resource-check/${SERVER_ID:-$server_file}"
  local cpu_line ram_line cpu_pct ram_pct summary=""
  local cpu_previous_state ram_previous_state cpu_current_state="ok" ram_current_state="ok"
  local exit_code=0

  cpu_previous_state=$(read_metric_state "$state_dir" "cpu")
  ram_previous_state=$(read_metric_state "$state_dir" "ram")

  cpu_line=$(run_host_cmd 'read -r _ user nice system idle iowait irq softirq steal _ < /proc/stat; total1=$((user+nice+system+idle+iowait+irq+softirq+steal)); idle1=$((idle+iowait)); sleep 1; read -r _ user nice system idle iowait irq softirq steal _ < /proc/stat; total2=$((user+nice+system+idle+iowait+irq+softirq+steal)); idle2=$((idle+iowait)); diff_total=$((total2-total1)); diff_idle=$((idle2-idle1)); if [ "$diff_total" -gt 0 ]; then echo $((((diff_total-diff_idle)*100)/diff_total)); else echo 0; fi' || true)
  ram_line=$(run_host_cmd "free | awk '/Mem:/ {if (\$2 > 0) printf \"%.0f\", (\$3*100)/\$2; else printf \"0\"}'" || true)
  cpu_pct="${cpu_line:-0}"
  ram_pct="${ram_line:-0}"
  summary+="cpu ${cpu_pct}% threshold=${cpu_threshold}%\n"
  summary+="ram ${ram_pct}% threshold=${ram_threshold}%\n"

  if [[ "${cpu_pct:-0}" -ge "$cpu_threshold" ]]; then
    cpu_current_state="critical"
    exit_code=2
  fi
  if [[ "${ram_pct:-0}" -ge "$ram_threshold" ]]; then
    ram_current_state="critical"
    exit_code=2
  fi

  write_metric_state "$state_dir" "cpu" "$cpu_current_state"
  write_metric_state "$state_dir" "ram" "$ram_current_state"
  printf '%b' "$summary"

  if [[ "$cpu_current_state" == "critical" && "$cpu_previous_state" != "critical" ]]; then
    telegram_send_if_enabled "TELEGRAM_NOTIFY_CPU_ALERT" "Orbix CPU alert on ${SERVER_ID:-$server_file}\nusage=${cpu_pct}%\nthreshold=${cpu_threshold}%" "true"
  fi
  if [[ "$cpu_current_state" == "ok" && "$cpu_previous_state" == "critical" ]]; then
    telegram_send_if_enabled "TELEGRAM_NOTIFY_CPU_RECOVERY" "Orbix CPU recovered on ${SERVER_ID:-$server_file}\nusage=${cpu_pct}%\nthreshold=${cpu_threshold}%" "false"
  fi
  if [[ "$ram_current_state" == "critical" && "$ram_previous_state" != "critical" ]]; then
    telegram_send_if_enabled "TELEGRAM_NOTIFY_RAM_ALERT" "Orbix RAM alert on ${SERVER_ID:-$server_file}\nusage=${ram_pct}%\nthreshold=${ram_threshold}%" "true"
  fi
  if [[ "$ram_current_state" == "ok" && "$ram_previous_state" == "critical" ]]; then
    telegram_send_if_enabled "TELEGRAM_NOTIFY_RAM_RECOVERY" "Orbix RAM recovered on ${SERVER_ID:-$server_file}\nusage=${ram_pct}%\nthreshold=${ram_threshold}%" "false"
  fi

  return "$exit_code"
}

run_docker_check() {
  local server_file="$1"
  load_server_env "$server_file"
  local state_file="${STATE_DIR:-/var/lib/backup}/docker-check/${SERVER_ID:-$server_file}.state"
  local previous_exists=false
  local raw names filters=() entries=() name status health restarts derived detail
  local current_keys=()
  local exit_code=0

  while IFS= read -r token; do
    [[ -n "$token" ]] && filters+=("$token")
  done < <(normalize_token_list "${DOCKER_ALERT_CONTAINERS:-}")

  [[ -f "$state_file" ]] && previous_exists=true
  raw=$(run_host_cmd 'ids=$(docker ps -aq 2>/dev/null || true); if [ -n "$ids" ]; then docker inspect --format "{{.Name}}|{{.State.Status}}|{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}|{{.RestartCount}}" $ids | sed "s#^/##"; fi' || true)

  while IFS='|' read -r name status health restarts; do
    [[ -n "${name:-}" ]] || continue
    if ! matches_token_filter "$name" "${filters[@]}"; then
      continue
    fi
    derived="$status"
    if [[ "$status" == "running" && "$health" == "unhealthy" ]]; then
      derived="unhealthy"
    elif [[ "$status" == "running" ]]; then
      derived="running"
    elif [[ "$status" == "restarting" || "$status" == "dead" ]]; then
      derived="error"
    elif [[ "$status" == "exited" ]]; then
      derived="stopped"
    elif [[ "$status" == "created" ]]; then
      derived="created"
    else
      derived="$status"
    fi
    detail="status=${status},health=${health},restarts=${restarts}"
    entries+=("${name}|${derived}|${detail}")
    current_keys+=("$name")
    printf '%s %s %s\n' "$name" "$derived" "$detail"

    if [[ "$derived" != "running" ]]; then
      exit_code=2
    fi

    if [[ "$previous_exists" == true ]]; then
      local previous_state previous_detail
      previous_state=$(state_value_for_key "$state_file" "$name" || true)
      previous_detail=$(state_detail_for_key "$state_file" "$name" || true)
      if [[ -z "$previous_state" ]]; then
        continue
      fi
      if [[ "$previous_state" != "$derived" ]]; then
        case "$derived" in
          running)
            telegram_send_if_enabled "TELEGRAM_NOTIFY_DOCKER_START" "Orbix Docker start on ${SERVER_ID:-$server_file}\ncontainer=${name}\n${detail}" "true"
            if [[ "$previous_state" == "unhealthy" || "$previous_state" == "error" || "$previous_state" == "stopped" ]]; then
              telegram_send_if_enabled "TELEGRAM_NOTIFY_DOCKER_RECOVERY" "Orbix Docker recovery on ${SERVER_ID:-$server_file}\ncontainer=${name}\nfrom=${previous_state}\n${detail}" "false"
            fi
            ;;
          stopped)
            telegram_send_if_enabled "TELEGRAM_NOTIFY_DOCKER_STOP" "Orbix Docker stop on ${SERVER_ID:-$server_file}\ncontainer=${name}\n${detail}" "true"
            ;;
          unhealthy)
            telegram_send_if_enabled "TELEGRAM_NOTIFY_DOCKER_UNHEALTHY" "Orbix Docker unhealthy on ${SERVER_ID:-$server_file}\ncontainer=${name}\n${detail}" "true"
            ;;
          error)
            telegram_send_if_enabled "TELEGRAM_NOTIFY_DOCKER_ERROR" "Orbix Docker error on ${SERVER_ID:-$server_file}\ncontainer=${name}\n${detail}" "true"
            ;;
        esac
      elif [[ "$derived" == "running" && "$detail" != "$previous_detail" && "$previous_detail" == *"health=unhealthy"* ]]; then
        telegram_send_if_enabled "TELEGRAM_NOTIFY_DOCKER_RECOVERY" "Orbix Docker recovery on ${SERVER_ID:-$server_file}\ncontainer=${name}\n${detail}" "false"
      fi
    fi
  done <<<"$raw"

  if [[ "$previous_exists" == true ]]; then
    local previous_key found
    while IFS= read -r previous_key; do
      [[ -n "$previous_key" ]] || continue
      found=false
      for name in "${current_keys[@]}"; do
        if [[ "$name" == "$previous_key" ]]; then
          found=true
          break
        fi
      done
      if [[ "$found" == false ]]; then
        telegram_send_if_enabled "TELEGRAM_NOTIFY_DOCKER_STOP" "Orbix Docker container missing on ${SERVER_ID:-$server_file}\ncontainer=${previous_key}" "true"
      fi
    done < <(state_keys "$state_file")
  fi

  write_state_entries "$state_file" "${entries[@]}"
  return "$exit_code"
}

run_k8s_check() {
  local server_file="$1"
  load_server_env "$server_file"
  local state_file="${STATE_DIR:-/var/lib/backup}/k8s-check/${SERVER_ID:-$server_file}.state"
  local previous_exists=false
  local namespaces=() raw_pods raw_workloads entries=() key state detail exit_code=0
  local ns kind name phase reasons ready restarts desired available updated

  while IFS= read -r token; do
    [[ -n "$token" ]] && namespaces+=("$token")
  done < <(normalize_token_list "${K8S_NAMESPACE_TARGETS:-}")

  [[ -f "$state_file" ]] && previous_exists=true

  raw_pods=$(run_host_cmd "kubectl get pods -A -o jsonpath='{range .items[*]}{.metadata.namespace}{\"|\"}{.metadata.name}{\"|\"}{.status.phase}{\"|\"}{range .status.containerStatuses[*]}{.state.waiting.reason}{\",\"}{end}{\"|\"}{range .status.containerStatuses[*]}{.ready}{\",\"}{end}{\"|\"}{range .status.containerStatuses[*]}{.restartCount}{\",\"}{end}{\"\\n\"}{end}' 2>/dev/null || true")
  while IFS='|' read -r ns name phase reasons ready restarts; do
    [[ -n "${ns:-}" && -n "${name:-}" ]] || continue
    if ! matches_token_filter "$ns" "${namespaces[@]}"; then
      if [[ ${#namespaces[@]} -gt 0 ]]; then
        continue
      fi
    fi
    state="running"
    if [[ "$phase" == "Failed" || "$phase" == "Unknown" || "$reasons" =~ (CrashLoopBackOff|ImagePullBackOff|ErrImagePull|CreateContainerConfigError|CreateContainerError|RunContainerError|Error) ]]; then
      state="error"
      exit_code=2
    elif [[ "$phase" != "Running" ]]; then
      state="${phase,,}"
    fi
    key="pod:${ns}/${name}"
    detail="phase=${phase},reasons=${reasons:-none},ready=${ready:-unknown},restarts=${restarts:-0}"
    entries+=("${key}|${state}|${detail}")
    printf '%s %s %s\n' "$key" "$state" "$detail"

    if [[ "$previous_exists" == true ]]; then
      local previous_state
      previous_state=$(state_value_for_key "$state_file" "$key" || true)
      if [[ -n "$previous_state" && "$previous_state" != "$state" ]]; then
        if [[ "$state" == "error" ]]; then
          telegram_send_if_enabled "TELEGRAM_NOTIFY_K8S_POD_ERROR" "Orbix Kubernetes pod error on ${SERVER_ID:-$server_file}\npod=${ns}/${name}\n${detail}" "true"
        elif [[ "$state" == "running" ]]; then
          telegram_send_if_enabled "TELEGRAM_NOTIFY_K8S_POD_START" "Orbix Kubernetes pod running on ${SERVER_ID:-$server_file}\npod=${ns}/${name}\n${detail}" "false"
          if [[ "$previous_state" == "error" || "$previous_state" == "pending" || "$previous_state" == "failed" || "$previous_state" == "unknown" ]]; then
            telegram_send_if_enabled "TELEGRAM_NOTIFY_K8S_POD_RECOVERY" "Orbix Kubernetes pod recovered on ${SERVER_ID:-$server_file}\npod=${ns}/${name}\nfrom=${previous_state}\n${detail}" "false"
          fi
        fi
      fi
    fi
  done <<<"$raw_pods"

  raw_workloads=$(run_host_cmd "kubectl get deploy,statefulset -A -o jsonpath='{range .items[*]}{.kind}{\"|\"}{.metadata.namespace}{\"|\"}{.metadata.name}{\"|\"}{.spec.replicas}{\"|\"}{.status.readyReplicas}{\"|\"}{.status.availableReplicas}{\"|\"}{.status.updatedReplicas}{\"\\n\"}{end}' 2>/dev/null || true")
  while IFS='|' read -r kind ns name desired ready available updated; do
    [[ -n "${kind:-}" && -n "${ns:-}" && -n "${name:-}" ]] || continue
    if ! matches_token_filter "$ns" "${namespaces[@]}"; then
      if [[ ${#namespaces[@]} -gt 0 ]]; then
        continue
      fi
    fi
    desired="${desired:-0}"
    ready="${ready:-0}"
    available="${available:-0}"
    updated="${updated:-0}"
    state="running"
    if [[ "${ready:-0}" -lt "${desired:-0}" || "${available:-0}" -lt "${desired:-0}" ]]; then
      state="degraded"
      exit_code=2
    fi
    key="workload:${kind}:${ns}/${name}"
    detail="desired=${desired},ready=${ready},available=${available},updated=${updated}"
    entries+=("${key}|${state}|${detail}")
    printf '%s %s %s\n' "$key" "$state" "$detail"

    if [[ "$previous_exists" == true ]]; then
      local previous_state
      previous_state=$(state_value_for_key "$state_file" "$key" || true)
      if [[ -n "$previous_state" && "$previous_state" != "$state" ]]; then
        if [[ "$state" == "degraded" ]]; then
          telegram_send_if_enabled "TELEGRAM_NOTIFY_K8S_WORKLOAD_DEGRADED" "Orbix Kubernetes workload degraded on ${SERVER_ID:-$server_file}\nworkload=${kind} ${ns}/${name}\n${detail}" "true"
        elif [[ "$state" == "running" && "$previous_state" == "degraded" ]]; then
          telegram_send_if_enabled "TELEGRAM_NOTIFY_K8S_WORKLOAD_RECOVERY" "Orbix Kubernetes workload recovered on ${SERVER_ID:-$server_file}\nworkload=${kind} ${ns}/${name}\n${detail}" "false"
        fi
      fi
    fi
  done <<<"$raw_workloads"

  write_state_entries "$state_file" "${entries[@]}"
  return "$exit_code"
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
  orbix-ops.sh resource-check <server.env>
  orbix-ops.sh docker-check <server.env>
  orbix-ops.sh k8s-check <server.env>
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
  resource-check)
    run_resource_check "${2:?missing server env filename}"
    ;;
  docker-check)
    run_docker_check "${2:?missing server env filename}"
    ;;
  k8s-check)
    run_k8s_check "${2:?missing server env filename}"
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
