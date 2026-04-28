#!/usr/bin/env bash
set -Eeuo pipefail

TARGET_HOST="${1:?usage: install-rpi.sh user@host}"
TARGET_ROOT="${2:-/opt/backup-platform}"

rsync -az --delete \
  --exclude '.git' \
  ./ "$TARGET_HOST:$TARGET_ROOT/"

ssh "$TARGET_HOST" "sudo mkdir -p $TARGET_ROOT /etc/backup/servers.d /etc/backup/hooks.d /var/lib/orbix-ui && sudo chmod +x $TARGET_ROOT/scripts/*.sh $TARGET_ROOT/scripts/*.py $TARGET_ROOT/hooks/*.sh 2>/dev/null || true"
