# Orbix Usage

## Qué es

Orbix es la consola operativa para:

- backups de hosts completos
- backups de rutas, volúmenes y bases de datos
- restores desde snapshots restic
- monitoreo básico de disco y logs
- operación multi-servidor por SSH

## Runtime actual

En una Raspberry Pi o Linux operator host, Orbix suele vivir con este layout:

- código: `/opt/backup-platform`
- config global: `/etc/backup/global.env`
- perfiles por servidor: `/etc/backup/servers.d/*.env`
- logs: `/var/log/backup`
- estado: `/var/lib/backup`
- estado UI: `/var/lib/orbix-ui`

El nombre del repo es `server-backups`, pero el runtime actual puede seguir montado en `/opt/backup-platform` para no romper instalaciones ya existentes.

## UI web

### Qué expone

- `Dashboard`: estado general y últimas ejecuciones
- `Servers`: alta/edición de perfiles
- `Snapshots`: catálogo con tamaño, grupos y paths
- `Restores`: restores manuales
- `Jobs`: tracking de ejecuciones
- `Logs`: preview de logs de host, contenedores, DB, Nginx o Apache
- `Notifications`: configuración Telegram
- `Settings`: repo remoto, paths globales y retención por defecto
- chequeo de readiness del host con `doctor`
- prueba de conectividad SSH por perfil remoto

### Cómo levantarla

```bash
cd /opt/backup-platform
sudo mkdir -p /var/lib/orbix-ui
sudo docker compose -f deploy/backup-ui.compose.yml up -d --build
```

### URL local

```text
http://<ip-del-host>:8585
```

## Scheduling

Orbix soporta cron por servidor.

Campos clave:

- `BACKUP_ENABLED=true`
- `BACKUP_CRON="10 2 * * *"`
- `DISK_CHECK_ENABLED=true`
- `DISK_CHECK_CRON="*/30 * * * *"`

Ejecutar el dispatcher cada minuto:

```bash
* * * * * root /usr/bin/python3 /opt/backup-platform/scripts/orbix-dispatcher.py >> /var/log/backup/orbix-dispatcher.log 2>&1
```

## Configuración global

Archivo: `/etc/backup/global.env`

Campos principales:

- `RESTIC_RETENTION_DAILY`
- `RESTIC_RETENTION_WEEKLY`
- `RESTIC_RETENTION_MONTHLY`
- `SFTP_REPO_HOST`
- `SFTP_REPO_PORT`
- `SFTP_REPO_USER`
- `SFTP_REPO_BASE`
- `SFTP_SSH_KEY`
- `RESTIC_SFTP_COMMAND`
- `TELEGRAM_ENABLED`
- `TELEGRAM_BOT_TOKEN`
- `TELEGRAM_CHAT_ID`

## Configuración por servidor

Archivo: `/etc/backup/servers.d/<server>.env`

Campos base:

- `SERVER_ID`
- `SOURCE_ROLE`
- `SOURCE_MODE`
- `HOOK_SCRIPT`

### Local

- `HOST_PATHS`
- `HOST_PATHS_OPTIONAL`
- `DOCKER_VOLUMES`
- `LOCAL_POSTGRES_DUMPS`
- `LOCAL_MYSQL_DUMPS`
- `LOCAL_MONGO_DUMPS`

### Remoto por SSH

- `REMOTE_HOST`
- `REMOTE_PORT`
- `REMOTE_USER`
- `REMOTE_SSH_KEY`
- `REMOTE_PATHS`
- `REMOTE_PATHS_OPTIONAL`
- `REMOTE_DOCKER_VOLUMES`
- `REMOTE_POSTGRES_DUMPS`
- `REMOTE_MYSQL_DUMPS`
- `REMOTE_MONGO_DUMPS`
- `REMOTE_PRE_DUMP_COMMANDS`

### Retención por servidor

- `RETENTION_DAILY`
- `RETENTION_WEEKLY`
- `RETENTION_MONTHLY`

### Monitoreo de disco

- `DISK_THRESHOLD_PCT`
- `DISK_ALERT_TARGETS`

## Formatos de dumps

### PostgreSQL

```env
LOCAL_POSTGRES_DUMPS="main|postgres-container|postgres|appdb"
```

Formato:

`label|container|user|database`

### MySQL / MariaDB

```env
REMOTE_MYSQL_DUMPS="main|mysql-container|root|env:MYSQL_ROOT_PASSWORD|env:MYSQL_DATABASE"
```

Formato:

`label|container|user|password|database`

### MongoDB

```env
REMOTE_MONGO_DUMPS="crm|mongo-container|crmdb|mongodb://user:pass@127.0.0.1:27017/crmdb"
```

Formato:

`label|container|database|uri`

## Comandos clave

### Backup manual

```bash
sudo /opt/backup-platform/scripts/backup-runner.sh
sudo /opt/backup-platform/scripts/backup-runner.sh rpi-house.env
```

### Catálogo

```bash
sudo /opt/backup-platform/scripts/backup-restore-helper.sh list
sudo /opt/backup-platform/scripts/backup-restore-helper.sh snapshots rpi-house
```

### Restore

```bash
sudo /opt/backup-platform/scripts/backup-restore-helper.sh restore rpi-house <snapshot_id> /var/tmp/restore-rpi-house
```

### Logs operativos

```bash
sudo /opt/backup-platform/scripts/orbix-ops.sh logs vps-production.env system
sudo /opt/backup-platform/scripts/orbix-ops.sh logs vps-turnero-157.env docker moodle_db 200
```

### Disk check

```bash
sudo /opt/backup-platform/scripts/orbix-ops.sh disk-check vps-production.env
```

### Telegram test

```bash
sudo /opt/backup-platform/scripts/orbix-ops.sh test-telegram
```

### SSH test

```bash
sudo /opt/backup-platform/scripts/orbix-ops.sh ssh-test vps-production.env
```

### Doctor del host

```bash
sudo /opt/backup-platform/scripts/orbix-doctor.sh check
sudo /opt/backup-platform/scripts/orbix-doctor.sh check --json
sudo /opt/backup-platform/scripts/orbix-doctor.sh fix-perms
sudo /opt/backup-platform/scripts/orbix-doctor.sh install-missing
sudo /opt/backup-platform/scripts/orbix-doctor.sh bootstrap
```

`bootstrap`:

- crea directorios faltantes
- corrige permisos ejecutables
- instala paquetes necesarios si faltan

## Qué registra cada snapshot

Orbix guarda por ejecución:

- `server_id`
- `group_name`
- `paths_json`
- `source_size_bytes`
- `processed_bytes`
- `file_count`
- `duration_seconds`
- `created_at`
- `restic_short_id`

Esto permite mostrar en la UI:

- qué directorios o grupos incluyó
- cuánto pesaba el source
- cuánto terminó almacenando restic
- cuánto duró
- desde qué servidor provino

## Onboarding de un VPS nuevo

1. crear un `.env` nuevo en `/etc/backup/servers.d/`
2. usar `config/servers.d/remote-generic.env.example`
3. cargar `REMOTE_HOST`, `REMOTE_USER`, `REMOTE_SSH_KEY`
4. definir `REMOTE_PATHS`
5. definir volúmenes y dumps si aplica
6. elegir cron y retención
7. probar backup manual desde Orbix
8. verificar snapshot en UI y catálogo
