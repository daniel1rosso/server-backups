# Orbix Restore

## Flujo recomendado

1. identificar el `server_id`
2. listar snapshots disponibles
3. restaurar a staging
4. validar contenido
5. promover manualmente a destino final si corresponde

## Listado

```bash
sudo /opt/backup-platform/scripts/backup-restore-helper.sh list
sudo /opt/backup-platform/scripts/backup-restore-helper.sh snapshots rpi-house
```

## Restore a staging

```bash
sudo /opt/backup-platform/scripts/backup-restore-helper.sh restore rpi-house <snapshot_id> /var/tmp/restore-rpi-house
```

## Desde la UI

1. ir a `Restores`
2. elegir servidor
3. elegir snapshot
4. indicar target path
5. ejecutar restore
6. seguir el job desde `Jobs`

## Casos típicos

### Restaurar Dokploy

1. restaurar snapshot a staging
2. recuperar `/etc/dokploy`
3. restaurar `dokploy.sql` dentro de `dokploy-postgres`
4. validar configuración antes de reiniciar cualquier servicio

### Restaurar un volumen Docker

1. identificar el tar del volumen dentro del restore staging
2. detener el contenedor afectado
3. descomprimir sobre el mountpoint del volumen
4. iniciar el contenedor
5. validar datos y logs

### Restaurar una base

1. ubicar el dump en `db-dumps`
2. restaurar sobre instancia staging o mantenimiento
3. validar integridad
4. recién después promover

## Qué revisar antes de restaurar

- servidor correcto
- snapshot correcto
- target path correcto
- si el restore va a staging o producción
- si hay downtime planificado para la app afectada
