from __future__ import annotations

import os
import sqlite3
import subprocess
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path


GLOBAL_ENV = Path(os.environ.get("GLOBAL_ENV", "/etc/backup/global.env"))
SERVER_DIR = Path(os.environ.get("SERVER_DIR", "/etc/backup/servers.d"))
STATE_DIR = Path(os.environ.get("STATE_DIR", "/var/lib/backup"))
DB_PATH = STATE_DIR / "dispatcher.sqlite3"
PLATFORM_ROOT = Path(os.environ.get("PLATFORM_ROOT", "/opt/backup-platform"))


@dataclass
class ScheduledJob:
    job_key: str
    command: str
    cron_expr: str


def parse_env(path: Path) -> dict[str, str]:
    data: dict[str, str] = {}
    for raw_line in path.read_text().splitlines():
        line = raw_line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, value = line.split("=", 1)
        value = value.strip()
        if len(value) >= 2 and value[0] == value[-1] == '"':
            value = value[1:-1]
        data[key.strip()] = value
    return data


def ensure_db() -> None:
    STATE_DIR.mkdir(parents=True, exist_ok=True)
    conn = sqlite3.connect(DB_PATH)
    conn.execute(
        """
        create table if not exists scheduled_runs (
          job_key text primary key,
          last_minute text not null
        )
        """
    )
    conn.commit()
    conn.close()


def cron_match_field(field: str, value: int) -> bool:
    if field == "*":
      return True
    matched = False
    for part in field.split(","):
        part = part.strip()
        if not part:
            continue
        if part.startswith("*/"):
            step = int(part[2:])
            if value % step == 0:
                matched = True
        elif "-" in part:
            start_s, end_s = part.split("-", 1)
            if int(start_s) <= value <= int(end_s):
                matched = True
        else:
            normalized = 0 if value == 7 else value
            if int(part) == normalized or (value == 0 and int(part) == 7):
                matched = True
    return matched


def cron_matches(expr: str, dt: datetime) -> bool:
    parts = expr.split()
    if len(parts) != 5:
        return False
    minute, hour, dom, month, dow = parts
    weekday = (dt.weekday() + 1) % 7
    return (
        cron_match_field(minute, dt.minute)
        and cron_match_field(hour, dt.hour)
        and cron_match_field(dom, dt.day)
        and cron_match_field(month, dt.month)
        and cron_match_field(dow, weekday)
    )


def already_ran(job_key: str, minute_key: str) -> bool:
    conn = sqlite3.connect(DB_PATH)
    row = conn.execute("select last_minute from scheduled_runs where job_key=?", (job_key,)).fetchone()
    conn.close()
    return row is not None and row[0] == minute_key


def mark_ran(job_key: str, minute_key: str) -> None:
    conn = sqlite3.connect(DB_PATH)
    conn.execute(
        "insert into scheduled_runs(job_key, last_minute) values(?, ?) on conflict(job_key) do update set last_minute=excluded.last_minute",
        (job_key, minute_key),
    )
    conn.commit()
    conn.close()


def collect_jobs(server_filename: str, env: dict[str, str]) -> list[ScheduledJob]:
    jobs: list[ScheduledJob] = []
    if env.get("BACKUP_ENABLED", "true").lower() == "true":
        cron_expr = env.get("BACKUP_CRON", "")
        if cron_expr:
            jobs.append(
                ScheduledJob(
                    job_key=f"{server_filename}:backup",
                    command=f"{PLATFORM_ROOT}/scripts/backup-runner.sh {server_filename}",
                    cron_expr=cron_expr,
                )
            )
    if env.get("DISK_CHECK_ENABLED", "true").lower() == "true":
        cron_expr = env.get("DISK_CHECK_CRON", "")
        if cron_expr:
            jobs.append(
                ScheduledJob(
                    job_key=f"{server_filename}:disk-check",
                    command=f"{PLATFORM_ROOT}/scripts/orbix-ops.sh disk-check {server_filename}",
                    cron_expr=cron_expr,
                )
            )
    if env.get("RESOURCE_CHECK_ENABLED", "false").lower() == "true":
        cron_expr = env.get("RESOURCE_CHECK_CRON", "")
        if cron_expr:
            jobs.append(
                ScheduledJob(
                    job_key=f"{server_filename}:resource-check",
                    command=f"{PLATFORM_ROOT}/scripts/orbix-ops.sh resource-check {server_filename}",
                    cron_expr=cron_expr,
                )
            )
    if env.get("DOCKER_CHECK_ENABLED", "false").lower() == "true":
        cron_expr = env.get("DOCKER_CHECK_CRON", "")
        if cron_expr:
            jobs.append(
                ScheduledJob(
                    job_key=f"{server_filename}:docker-check",
                    command=f"{PLATFORM_ROOT}/scripts/orbix-ops.sh docker-check {server_filename}",
                    cron_expr=cron_expr,
                )
            )
    if env.get("K8S_CHECK_ENABLED", "false").lower() == "true":
        cron_expr = env.get("K8S_CHECK_CRON", "")
        if cron_expr:
            jobs.append(
                ScheduledJob(
                    job_key=f"{server_filename}:k8s-check",
                    command=f"{PLATFORM_ROOT}/scripts/orbix-ops.sh k8s-check {server_filename}",
                    cron_expr=cron_expr,
                )
            )
    return jobs


def main() -> int:
    if not GLOBAL_ENV.exists() or not SERVER_DIR.exists():
        return 1
    ensure_db()
    now = datetime.now(timezone.utc).astimezone()
    minute_key = now.strftime("%Y-%m-%dT%H:%M")
    server_files = sorted(p.name for p in SERVER_DIR.glob("*.env") if p.is_file())

    for server_filename in server_files:
        env = parse_env(SERVER_DIR / server_filename)
        for job in collect_jobs(server_filename, env):
            if not cron_matches(job.cron_expr, now):
                continue
            if already_ran(job.job_key, minute_key):
                continue
            subprocess.run(["/bin/bash", "-lc", job.command], check=False)
            mark_ran(job.job_key, minute_key)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
