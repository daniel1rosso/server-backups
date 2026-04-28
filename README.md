# Orbix

Orbix es una plataforma local para backups operativos, restores y observabilidad liviana de servidores Linux administrados por SSH.

Sirve para:

- respaldar hosts completos, no solo Dokploy
- respaldar configuraciones, rutas arbitrarias, volúmenes Docker y dumps de bases
- administrar múltiples VPS o servers con perfiles declarativos
- ejecutar restores simples desde una fuente identificable
- aplicar retención configurable
- enviar alertas por Telegram
- revisar snapshots, jobs, logs y espacio en disco desde una UI local

## Alcance actual

Orbix ya soporta:

- hosts locales y remotos por `SSH`
- PostgreSQL
- MySQL / MariaDB
- MongoDB
- Docker volumes
- configuraciones de Nginx, Apache, SSH, Dokploy y rutas custom
- catálogo local SQLite/JSON
- UI web en Docker
- jobs manuales de backup, restore, disk-check y captura de logs
- scheduling por cron declarativo por servidor

## Estructura

- `config/global.env.example`: configuración global
- `config/servers.d/*.env.example`: ejemplos de servidores
- `hooks/`: recolección local y remota
- `scripts/backup-runner.sh`: runner principal
- `scripts/backup-restore-helper.sh`: catálogo y restore
- `scripts/orbix-ops.sh`: disk checks, logs y Telegram test
- `scripts/orbix-dispatcher.py`: scheduler por cron declarativo
- `ui/`: UI Flask dockerizable
- `deploy/backup-ui.compose.yml`: despliegue local de la UI
- `docs/USAGE.md`: operación diaria
- `docs/RESTORE.md`: restores

## Modelo operativo

1. Cada servidor tiene un `.env`.
2. Cada perfil define modo, paths, volúmenes, dumps, retención y horarios.
3. Orbix ejecuta un hook de recolección.
4. El staging se empaqueta con `restic` hacia el repo remoto SFTP.
5. Se actualiza el catálogo local con snapshot, tamaño, paths y duración.
6. Se registran jobs y logs en la UI.
7. Telegram recibe alertas de backup y disco.

## UI

La UI Orbix está pensada para correr localmente en la Raspberry o host operador.

Vistas actuales:

- Dashboard
- Servers
- Snapshots
- Restores
- Jobs
- Logs
- Notifications
- Settings

La UI permite:

- agregar o editar servidores
- configurar rutas, volúmenes y dumps
- cambiar cron y retención
- lanzar backups y restores
- revisar qué incluye cada snapshot
- ver logs operativos del host o contenedores
- testear Telegram

## Branding

- nombre de plataforma: `Orbix`
- dirección visual: verde + celeste

## Siguiente operación

1. revisar `docs/USAGE.md`
2. copiar `config/global.env.example` a `/etc/backup/global.env`
3. crear perfiles en `/etc/backup/servers.d/`
4. desplegar la UI con `deploy/backup-ui.compose.yml`
5. configurar cron del dispatcher y del backup runner según el host destino
