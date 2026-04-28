from __future__ import annotations

import json
import os
import shlex
import sqlite3
import subprocess
import threading
import uuid
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

from flask import Flask, jsonify, redirect, render_template, request, url_for


PLATFORM_NAME = "Orbix"
APP_ROOT = Path(__file__).resolve().parent
PLATFORM_ROOT = Path(os.environ.get("PLATFORM_ROOT", "/opt/backup-platform"))
CONFIG_DIR = Path(os.environ.get("CONFIG_DIR", "/etc/backup"))
SERVERS_DIR = CONFIG_DIR / "servers.d"
GLOBAL_ENV_FILE = CONFIG_DIR / "global.env"
BACKUP_STATE_DIR = Path(os.environ.get("BACKUP_STATE_DIR", "/var/lib/backup"))
BACKUP_LOG_DIR = Path(os.environ.get("BACKUP_LOG_DIR", "/var/log/backup"))
UI_STATE_DIR = Path(os.environ.get("UI_STATE_DIR", "/var/lib/orbix-ui"))
UI_DB = UI_STATE_DIR / "ui.sqlite3"
UI_JOBS_DIR = UI_STATE_DIR / "jobs"
HOST_ENTER_MODE = os.environ.get("HOST_ENTER_MODE", "nsenter")
RUNNER_LOG = BACKUP_LOG_DIR / f"backup-runner-{datetime.now().strftime('%F')}.log"

GLOBAL_FIELD_KEYS = [
    "BACKUP_ROOT",
    "STATE_DIR",
    "LOG_DIR",
    "TMP_DIR",
    "RESTIC_PASSWORD_FILE",
    "RESTIC_RETENTION_DAILY",
    "RESTIC_RETENTION_WEEKLY",
    "RESTIC_RETENTION_MONTHLY",
    "TELEGRAM_ENABLED",
    "TELEGRAM_BOT_TOKEN",
    "TELEGRAM_CHAT_ID",
    "SFTP_REPO_HOST",
    "SFTP_REPO_PORT",
    "SFTP_REPO_USER",
    "SFTP_REPO_BASE",
    "SFTP_SSH_KEY",
    "RESTIC_SFTP_COMMAND",
]

SERVER_FIELD_KEYS = [
    "SERVER_ID",
    "SOURCE_ROLE",
    "SOURCE_MODE",
    "HOOK_SCRIPT",
    "BACKUP_ENABLED",
    "BACKUP_CRON",
    "DISK_CHECK_ENABLED",
    "DISK_CHECK_CRON",
    "DISK_THRESHOLD_PCT",
    "DISK_ALERT_TARGETS",
    "RETENTION_DAILY",
    "RETENTION_WEEKLY",
    "RETENTION_MONTHLY",
    "HOST_PATHS",
    "HOST_PATHS_OPTIONAL",
    "DOCKER_VOLUMES",
    "LOCAL_POSTGRES_DUMPS",
    "LOCAL_MYSQL_DUMPS",
    "LOCAL_MONGO_DUMPS",
    "REMOTE_HOST",
    "REMOTE_PORT",
    "REMOTE_USER",
    "REMOTE_SSH_KEY",
    "REMOTE_PATHS",
    "REMOTE_PATHS_OPTIONAL",
    "REMOTE_SYSTEM_EXPORT",
    "REMOTE_DOCKER_EXPORT",
    "REMOTE_DOCKER_VOLUMES",
    "REMOTE_PRE_DUMP_COMMANDS",
    "REMOTE_POSTGRES_DUMPS",
    "REMOTE_MYSQL_DUMPS",
    "REMOTE_MONGO_DUMPS",
]

DOCTOR_COMMAND = f"{PLATFORM_ROOT}/scripts/orbix-doctor.sh"


app = Flask(__name__, template_folder=str(APP_ROOT / "templates"), static_folder=str(APP_ROOT / "static"))


def utc_now() -> str:
    return datetime.now(timezone.utc).isoformat()


def ensure_dirs() -> None:
    UI_STATE_DIR.mkdir(parents=True, exist_ok=True)
    UI_JOBS_DIR.mkdir(parents=True, exist_ok=True)


def db_conn() -> sqlite3.Connection:
    conn = sqlite3.connect(UI_DB)
    conn.row_factory = sqlite3.Row
    return conn


def init_db() -> None:
    ensure_dirs()
    conn = db_conn()
    conn.executescript(
        """
        create table if not exists jobs (
          id text primary key,
          job_type text not null,
          status text not null,
          target text not null,
          command text not null,
          created_at text not null,
          started_at text,
          finished_at text,
          exit_code integer,
          log_path text not null,
          payload_json text not null
        );
        """
    )
    conn.commit()
    conn.close()


def parse_env_text(text: str) -> dict[str, str]:
    data: dict[str, str] = {}
    for raw_line in text.splitlines():
        line = raw_line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, value = line.split("=", 1)
        value = value.strip()
        if len(value) >= 2 and value[0] == value[-1] == '"':
            value = value[1:-1]
        data[key.strip()] = value
    return data


def serialize_env(data: dict[str, str]) -> str:
    lines: list[str] = []
    for key in SERVER_FIELD_KEYS:
        value = data.get(key, "")
        if value == "":
            continue
        if any(ch.isspace() for ch in value) or value in {"true", "false"} or "|" in value or ";" in value or ":" in value:
            lines.append(f'{key}="{value}"')
        else:
            lines.append(f"{key}={value}")
    extra = data.get("__extra__", "").strip()
    if extra:
        lines.append("")
        lines.append(extra)
    return "\n".join(lines).rstrip() + "\n"


def read_text(path: Path) -> str:
    if not path.exists():
        return ""
    return path.read_text()


def write_text(path: Path, text: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(text)


def host_command(command: str) -> list[str]:
    if HOST_ENTER_MODE == "nsenter":
        return ["nsenter", "-t", "1", "-m", "-u", "-i", "-n", "-p", "--", "/bin/bash", "-lc", command]
    return ["/bin/bash", "-lc", command]


def run_host_capture(command: str) -> subprocess.CompletedProcess[str]:
    try:
        return subprocess.run(
            host_command(command),
            capture_output=True,
            text=True,
            check=False,
        )
    except FileNotFoundError:
        return subprocess.run(
            ["/bin/bash", "-lc", command],
            capture_output=True,
            text=True,
            check=False,
        )


def load_global_env() -> dict[str, str]:
    return parse_env_text(read_text(GLOBAL_ENV_FILE))


def global_form_data() -> dict[str, str]:
    env = load_global_env()
    payload = {key: env.get(key, "") for key in GLOBAL_FIELD_KEYS}
    raw = read_text(GLOBAL_ENV_FILE)
    extra_lines: list[str] = []
    for line in raw.splitlines():
        stripped = line.strip()
        if not stripped or stripped.startswith("#") or "=" not in stripped:
            extra_lines.append(line)
            continue
        key = stripped.split("=", 1)[0].strip()
        if key not in GLOBAL_FIELD_KEYS:
            extra_lines.append(line)
    payload["raw"] = raw
    payload["raw_extra"] = "\n".join(extra_lines).strip()
    return payload


def normalize_server_data(data: dict[str, str], filename: str) -> dict[str, Any]:
    normalized = {key: data.get(key, "") for key in SERVER_FIELD_KEYS}
    normalized["filename"] = filename
    normalized["raw"] = read_text(SERVERS_DIR / filename)
    normalized["repo_path"] = server_repo_path(normalized.get("SERVER_ID", Path(filename).stem))
    normalized["display_mode"] = "Remote SSH" if normalized.get("SOURCE_MODE") == "ssh_pull" else "Local host"
    normalized["paths_summary"] = normalized.get("REMOTE_PATHS") or normalized.get("HOST_PATHS") or "-"
    normalized["volumes_summary"] = normalized.get("REMOTE_DOCKER_VOLUMES") or normalized.get("DOCKER_VOLUMES") or "-"
    normalized["schedule_summary"] = normalized.get("BACKUP_CRON") or "-"
    normalized["disk_schedule_summary"] = normalized.get("DISK_CHECK_CRON") or "-"
    normalized["retention_summary"] = (
        f"D{normalized.get('RETENTION_DAILY') or 'default'} / "
        f"W{normalized.get('RETENTION_WEEKLY') or 'default'} / "
        f"M{normalized.get('RETENTION_MONTHLY') or 'default'}"
    )
    normalized["database_summary"] = ", ".join(
        filter(
            None,
            [
                "PostgreSQL" if normalized.get("REMOTE_POSTGRES_DUMPS") or normalized.get("LOCAL_POSTGRES_DUMPS") else "",
                "MySQL" if normalized.get("REMOTE_MYSQL_DUMPS") or normalized.get("LOCAL_MYSQL_DUMPS") else "",
                "MongoDB" if normalized.get("REMOTE_MONGO_DUMPS") or normalized.get("LOCAL_MONGO_DUMPS") else "",
            ],
        )
    ) or "-"
    extra_lines: list[str] = []
    for line in normalized["raw"].splitlines():
        stripped = line.strip()
        if not stripped or stripped.startswith("#") or "=" not in stripped:
            extra_lines.append(line)
            continue
        key = stripped.split("=", 1)[0].strip()
        if key not in SERVER_FIELD_KEYS:
            extra_lines.append(line)
    normalized["extra_env"] = "\n".join(extra_lines).strip()
    return normalized


def list_server_files() -> list[Path]:
    if not SERVERS_DIR.exists():
        return []
    return sorted([path for path in SERVERS_DIR.glob("*.env") if path.is_file()])


def load_server_envs() -> list[dict[str, Any]]:
    items = []
    for path in list_server_files():
        items.append(normalize_server_data(parse_env_text(read_text(path)), path.name))
    return items


def get_server_by_filename(filename: str) -> dict[str, Any] | None:
    path = SERVERS_DIR / filename
    if not path.exists():
        return None
    return normalize_server_data(parse_env_text(read_text(path)), filename)


def server_repo_path(server_id: str) -> str:
    env = load_global_env()
    host = env.get("SFTP_REPO_HOST", "")
    user = env.get("SFTP_REPO_USER", "")
    base = env.get("SFTP_REPO_BASE", "")
    return f"sftp:{user}@{host}:{base}/{server_id}"


def read_catalog_runs(limit: int = 250) -> list[dict[str, Any]]:
    catalog_db = BACKUP_STATE_DIR / "catalog" / "backups.sqlite3"
    if not catalog_db.exists():
        return []
    conn = sqlite3.connect(catalog_db)
    conn.row_factory = sqlite3.Row
    rows = conn.execute("select * from runs order by id desc limit ?", (limit,)).fetchall()
    conn.close()
    return [dict(row) for row in rows]


def read_snapshot_index() -> dict[str, Any]:
    catalog_dir = BACKUP_STATE_DIR / "catalog"
    result: dict[str, Any] = {}
    if not catalog_dir.exists():
        return result
    for path in sorted(catalog_dir.glob("*-snapshots.json")):
        server_id = path.name.removesuffix("-snapshots.json")
        try:
            result[server_id] = json.loads(path.read_text())
        except json.JSONDecodeError:
            result[server_id] = []
    return result


def read_ui_jobs(limit: int = 200) -> list[dict[str, Any]]:
    conn = db_conn()
    rows = conn.execute(
        "select id, job_type, status, target, command, created_at, started_at, finished_at, exit_code, log_path, payload_json from jobs order by created_at desc limit ?",
        (limit,),
    ).fetchall()
    conn.close()
    return [dict(row) for row in rows]


def doctor_status() -> dict[str, Any]:
    result = run_host_capture(f"{DOCTOR_COMMAND} check --json")
    if result.returncode != 0:
        return {
            "ok": False,
            "missing_commands": [],
            "missing_paths": [],
            "nonexec_paths": [],
            "error": (result.stdout + "\n" + result.stderr).strip(),
        }
    try:
        payload = json.loads(result.stdout.strip() or "{}")
    except json.JSONDecodeError:
        payload = {
            "ok": False,
            "missing_commands": [],
            "missing_paths": [],
            "nonexec_paths": [],
            "error": result.stdout.strip() or result.stderr.strip() or "invalid doctor output",
        }
    payload.setdefault("missing_commands", [])
    payload.setdefault("missing_paths", [])
    payload.setdefault("nonexec_paths", [])
    return payload


def human_bytes(value: Any) -> str:
    try:
        size = float(value or 0)
    except (TypeError, ValueError):
        return "-"
    units = ["B", "KiB", "MiB", "GiB", "TiB"]
    idx = 0
    while size >= 1024 and idx < len(units) - 1:
        size /= 1024
        idx += 1
    return f"{size:.1f} {units[idx]}"


def metrics_summary() -> dict[str, Any]:
    runs = read_catalog_runs(500)
    servers = load_server_envs()
    jobs = read_ui_jobs(500)
    total_source_bytes = sum(int(run.get("source_size_bytes") or 0) for run in runs)
    failed_jobs = sum(1 for job in jobs if job["status"] == "failed")
    latest_run = runs[0]["created_at"] if runs else None
    return {
        "server_count": len(servers),
        "run_count": len(runs),
        "job_count": len(jobs),
        "failed_jobs": failed_jobs,
        "snapshot_count": sum(len(items) for items in read_snapshot_index().values()),
        "total_source_bytes": human_bytes(total_source_bytes),
        "latest_run": latest_run,
    }


def repo_metrics() -> list[dict[str, Any]]:
    snapshots = read_snapshot_index()
    runs = read_catalog_runs(500)
    latest_by_server: dict[str, dict[str, Any]] = {}
    for run in runs:
        latest_by_server.setdefault(run["server_id"], run)
    result: list[dict[str, Any]] = []
    for server in load_server_envs():
        latest = latest_by_server.get(server["SERVER_ID"])
        result.append(
            {
                "server_id": server["SERVER_ID"],
                "filename": server["filename"],
                "source_role": server["SOURCE_ROLE"],
                "snapshot_count": len(snapshots.get(server["SERVER_ID"], [])),
                "latest_run": latest["created_at"] if latest else None,
                "repo_path": server["repo_path"],
                "backup_cron": server["BACKUP_CRON"] or "-",
                "disk_cron": server["DISK_CHECK_CRON"] or "-",
            }
        )
    return result


def read_log_tail(path: Path, lines: int = 160) -> str:
    if not path.exists():
        return ""
    content = path.read_text(errors="ignore").splitlines()
    return "\n".join(content[-lines:])


def create_job(job_type: str, target: str, command: str, payload: dict[str, Any]) -> dict[str, Any]:
    job_id = uuid.uuid4().hex[:12]
    log_path = str(UI_JOBS_DIR / f"{job_id}.log")
    created_at = utc_now()
    conn = db_conn()
    conn.execute(
        """
        insert into jobs(id, job_type, status, target, command, created_at, started_at, finished_at, exit_code, log_path, payload_json)
        values(?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        """,
        (job_id, job_type, "queued", target, command, created_at, None, None, None, log_path, json.dumps(payload)),
    )
    conn.commit()
    conn.close()
    return {
        "id": job_id,
        "job_type": job_type,
        "status": "queued",
        "target": target,
        "created_at": created_at,
        "log_path": log_path,
        "payload_json": json.dumps(payload),
    }


def update_job(job_id: str, **fields: Any) -> None:
    if not fields:
        return
    assignments = ", ".join(f"{key}=?" for key in fields)
    values = list(fields.values()) + [job_id]
    conn = db_conn()
    conn.execute(f"update jobs set {assignments} where id=?", values)
    conn.commit()
    conn.close()


def run_job_async(job: dict[str, Any], command: str) -> None:
    def worker() -> None:
        update_job(job["id"], status="running", started_at=utc_now())
        with open(job["log_path"], "w", encoding="utf-8") as log_file:
            process = subprocess.Popen(
                host_command(command),
                stdout=log_file,
                stderr=subprocess.STDOUT,
                text=True,
            )
            return_code = process.wait()
        update_job(
            job["id"],
            status="done" if return_code == 0 else "failed",
            finished_at=utc_now(),
            exit_code=return_code,
        )

    thread = threading.Thread(target=worker, daemon=True)
    thread.start()


def queue_job(job_type: str, target: str, command: str, payload: dict[str, Any]) -> dict[str, Any]:
    job = create_job(job_type, target, command, payload)
    run_job_async(job, command)
    return job


def queue_backup(server_filename: str | None) -> dict[str, Any]:
    command = f"{PLATFORM_ROOT}/scripts/backup-runner.sh"
    target = server_filename or "all"
    if server_filename:
        command += f" {shlex.quote(server_filename)}"
    return queue_job("backup", target, command, {"server_filename": server_filename})


def queue_restore(server_id: str, snapshot_id: str, target_dir: str) -> dict[str, Any]:
    command = (
        f"{PLATFORM_ROOT}/scripts/backup-restore-helper.sh restore "
        f"{shlex.quote(server_id)} {shlex.quote(snapshot_id)} {shlex.quote(target_dir)}"
    )
    return queue_job(
        "restore",
        server_id,
        command,
        {"server_id": server_id, "snapshot_id": snapshot_id, "target_dir": target_dir},
    )


def queue_disk_check(server_filename: str) -> dict[str, Any]:
    command = f"{PLATFORM_ROOT}/scripts/orbix-ops.sh disk-check {shlex.quote(server_filename)}"
    return queue_job("disk-check", server_filename, command, {"server_filename": server_filename})


def queue_log_capture(server_filename: str, source_name: str, target_name: str, lines: int) -> dict[str, Any]:
    command = (
        f"{PLATFORM_ROOT}/scripts/orbix-ops.sh logs "
        f"{shlex.quote(server_filename)} {shlex.quote(source_name)} {shlex.quote(target_name)} {int(lines)}"
    )
    return queue_job(
        "log-capture",
        server_filename,
        command,
        {
            "server_filename": server_filename,
            "source_name": source_name,
            "target_name": target_name,
            "lines": lines,
        },
    )


def queue_test_telegram() -> dict[str, Any]:
    command = f"{PLATFORM_ROOT}/scripts/orbix-ops.sh test-telegram"
    return queue_job("test-telegram", "global", command, {})


def queue_doctor(action_name: str) -> dict[str, Any]:
    command = f"{DOCTOR_COMMAND} {shlex.quote(action_name)}"
    return queue_job(f"doctor-{action_name}", "host", command, {"action_name": action_name})


def queue_ssh_test(server_filename: str) -> dict[str, Any]:
    command = f"{PLATFORM_ROOT}/scripts/orbix-ops.sh ssh-test {shlex.quote(server_filename)}"
    return queue_job("ssh-test", server_filename, command, {"server_filename": server_filename})


def load_snapshot_rows() -> list[dict[str, Any]]:
    rows = read_catalog_runs(500)
    grouped: list[dict[str, Any]] = []
    for row in rows:
        item = dict(row)
        try:
            item["paths"] = json.loads(item.get("paths_json") or "[]")
        except json.JSONDecodeError:
            item["paths"] = []
        item["source_size_human"] = human_bytes(item.get("source_size_bytes"))
        item["processed_size_human"] = human_bytes(item.get("processed_bytes"))
        grouped.append(item)
    return grouped


def preview_logs(server_filename: str, source_name: str, target_name: str, lines: int) -> tuple[str, int]:
    command = (
        f"{PLATFORM_ROOT}/scripts/orbix-ops.sh logs "
        f"{shlex.quote(server_filename)} {shlex.quote(source_name)} {shlex.quote(target_name)} {int(lines)}"
    )
    result = run_host_capture(command)
    text = result.stdout
    if result.stderr:
        text += ("\n" if text else "") + result.stderr
    return text.strip(), result.returncode


def global_env_from_form(form: Any) -> str:
    data = {key: form.get(key, "").strip() for key in GLOBAL_FIELD_KEYS}
    lines = []
    for key in GLOBAL_FIELD_KEYS:
        value = data.get(key, "")
        if value == "":
            continue
        if any(ch.isspace() for ch in value) or "|" in value or ":" in value:
            lines.append(f'{key}="{value}"')
        else:
            lines.append(f"{key}={value}")
    raw_extra = form.get("raw_extra", "").strip()
    if raw_extra:
        lines.append("")
        lines.append(raw_extra)
    return "\n".join(lines).rstrip() + "\n"


def server_env_from_form(form: Any) -> str:
    data = {key: form.get(key, "").strip() for key in SERVER_FIELD_KEYS}
    data["__extra__"] = form.get("extra_env", "").strip()
    if not data["HOOK_SCRIPT"]:
        data["HOOK_SCRIPT"] = "hooks/pre_remote_generic.sh" if data["SOURCE_MODE"] == "ssh_pull" else "hooks/pre_local_rpi.sh"
    return serialize_env(data)


@app.template_filter("human_bytes")
def human_bytes_filter(value: Any) -> str:
    return human_bytes(value)


@app.context_processor
def inject_globals() -> dict[str, Any]:
    return {
        "platform_name": PLATFORM_NAME,
        "platform_root": str(PLATFORM_ROOT),
        "config_dir": str(CONFIG_DIR),
        "state_dir": str(BACKUP_STATE_DIR),
    }


@app.get("/")
def dashboard() -> str:
    return render_template(
        "dashboard.html",
        summary=metrics_summary(),
        repo_metrics=repo_metrics(),
        jobs=read_ui_jobs(10),
        runs=load_snapshot_rows()[:12],
        runner_log=read_log_tail(RUNNER_LOG),
        doctor=doctor_status(),
    )


@app.get("/servers")
def servers() -> str:
    return render_template("servers.html", servers=load_server_envs())


@app.post("/servers/save")
def save_server() -> Any:
    filename = request.form.get("filename", "").strip()
    if not filename:
        return redirect(url_for("servers"))
    if not filename.endswith(".env"):
        filename += ".env"
    write_text(SERVERS_DIR / filename, server_env_from_form(request.form))
    return redirect(url_for("servers"))


@app.post("/servers/delete")
def delete_server() -> Any:
    filename = request.form.get("filename", "").strip()
    path = SERVERS_DIR / filename
    if path.exists():
        path.unlink()
    return redirect(url_for("servers"))


@app.get("/snapshots")
def snapshots() -> str:
    return render_template("snapshots.html", runs=load_snapshot_rows(), repo_metrics=repo_metrics())


@app.get("/restores")
def restores() -> str:
    restore_jobs = [job for job in read_ui_jobs(100) if job["job_type"] == "restore"]
    return render_template("restores.html", servers=load_server_envs(), restore_jobs=restore_jobs, snapshots=read_snapshot_index())


@app.get("/jobs")
def jobs() -> str:
    return render_template("jobs.html", jobs=read_ui_jobs(200), servers=load_server_envs(), doctor=doctor_status())


@app.get("/jobs/<job_id>")
def job_detail(job_id: str) -> Any:
    conn = db_conn()
    row = conn.execute("select * from jobs where id=?", (job_id,)).fetchone()
    conn.close()
    if row is None:
        return "job not found", 404
    job = dict(row)
    return render_template("job_detail.html", job=job, log_text=read_log_tail(Path(job["log_path"]), 500))


@app.get("/logs")
def logs_view() -> str:
    servers = load_server_envs()
    server_filename = request.args.get("server_filename", servers[0]["filename"] if servers else "")
    source_name = request.args.get("source_name", "system")
    target_name = request.args.get("target_name", "")
    lines = int(request.args.get("lines", "200"))
    log_text = ""
    exit_code = None
    if server_filename:
        log_text, exit_code = preview_logs(server_filename, source_name, target_name, lines)
    return render_template(
        "logs.html",
        servers=servers,
        server_filename=server_filename,
        source_name=source_name,
        target_name=target_name,
        lines=lines,
        log_text=log_text,
        exit_code=exit_code,
    )


@app.get("/notifications")
def notifications() -> str:
    settings = global_form_data()
    return render_template("notifications.html", settings=settings)


@app.get("/settings")
def settings() -> str:
    return render_template("settings.html", settings=global_form_data())


@app.post("/settings/save")
def save_settings() -> Any:
    write_text(GLOBAL_ENV_FILE, global_env_from_form(request.form))
    return redirect(url_for("settings"))


@app.post("/notifications/save")
def save_notifications() -> Any:
    current = load_global_env()
    current["TELEGRAM_ENABLED"] = request.form.get("TELEGRAM_ENABLED", "false")
    current["TELEGRAM_BOT_TOKEN"] = request.form.get("TELEGRAM_BOT_TOKEN", "").strip()
    current["TELEGRAM_CHAT_ID"] = request.form.get("TELEGRAM_CHAT_ID", "").strip()
    lines: list[str] = []
    known = set()
    for key in GLOBAL_FIELD_KEYS:
        value = current.get(key, "")
        if value == "":
            continue
        known.add(key)
        lines.append(f'{key}="{value}"' if any(ch.isspace() for ch in value) else f"{key}={value}")
    raw = read_text(GLOBAL_ENV_FILE)
    for line in raw.splitlines():
        stripped = line.strip()
        if not stripped or stripped.startswith("#") or "=" not in stripped:
            lines.append(line)
            continue
        key = stripped.split("=", 1)[0].strip()
        if key not in known:
            lines.append(line)
    payload = "\n".join(line for line in lines if line is not None)
    write_text(GLOBAL_ENV_FILE, payload.rstrip() + "\n")
    return redirect(url_for("notifications"))


@app.post("/actions/backup")
def action_backup() -> Any:
    server_filename = request.form.get("server_filename") or None
    job = queue_backup(server_filename)
    return redirect(url_for("job_detail", job_id=job["id"]))


@app.post("/actions/restore")
def action_restore() -> Any:
    job = queue_restore(
        request.form["server_id"].strip(),
        request.form["snapshot_id"].strip(),
        request.form["target_dir"].strip(),
    )
    return redirect(url_for("job_detail", job_id=job["id"]))


@app.post("/actions/disk-check")
def action_disk_check() -> Any:
    job = queue_disk_check(request.form["server_filename"].strip())
    return redirect(url_for("job_detail", job_id=job["id"]))


@app.post("/actions/log-capture")
def action_log_capture() -> Any:
    job = queue_log_capture(
        request.form["server_filename"].strip(),
        request.form["source_name"].strip(),
        request.form.get("target_name", "").strip(),
        int(request.form.get("lines", "200")),
    )
    return redirect(url_for("job_detail", job_id=job["id"]))


@app.post("/actions/test-telegram")
def action_test_telegram() -> Any:
    job = queue_test_telegram()
    return redirect(url_for("job_detail", job_id=job["id"]))


@app.post("/actions/doctor/<action_name>")
def action_doctor(action_name: str) -> Any:
    if action_name not in {"check", "fix-perms", "install-missing", "bootstrap"}:
        return "unsupported doctor action", 400
    job = queue_doctor(action_name)
    return redirect(url_for("job_detail", job_id=job["id"]))


@app.post("/actions/ssh-test")
def action_ssh_test() -> Any:
    job = queue_ssh_test(request.form["server_filename"].strip())
    return redirect(url_for("job_detail", job_id=job["id"]))


@app.get("/api/jobs/<job_id>")
def job_json(job_id: str) -> Any:
    conn = db_conn()
    row = conn.execute("select * from jobs where id=?", (job_id,)).fetchone()
    conn.close()
    if row is None:
        return jsonify({"error": "not found"}), 404
    job = dict(row)
    job["log_tail"] = read_log_tail(Path(job["log_path"]), 120)
    return jsonify(job)


@app.get("/api/health")
def health() -> Any:
    return jsonify({"status": "ok", "platform": PLATFORM_NAME, "time": utc_now()})


init_db()


if __name__ == "__main__":
    app.run(host="0.0.0.0", port=8080, debug=True)
