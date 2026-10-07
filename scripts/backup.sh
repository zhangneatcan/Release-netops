#!/bin/bash
# 升级前备份，出问题可以回滚
set -euo pipefail
cd "$(dirname "$0")/.."

TS=$(date +%Y%m%d_%H%M)
BACKUP_DIR="/opt/nexora-backups"
mkdir -p "$BACKUP_DIR"

echo ">>> 备份数据库..."
docker compose exec -T db pg_dump -U postgres -d netops > "$BACKUP_DIR/db-$TS.sql"
echo "  -> $BACKUP_DIR/db-$TS.sql"

echo ">>> 备份 git 当前提交"
git rev-parse HEAD > "$BACKUP_DIR/commit-$TS.txt"
echo "  -> $BACKUP_DIR/commit-$TS.txt"

echo ">>> 备份 docker-compose 文件"
cp docker-compose.yml "$BACKUP_DIR/docker-compose-$TS.yml"
[ -f docker-compose.override.yml ] && cp docker-compose.override.yml "$BACKUP_DIR/docker-compose.override-$TS.yml"
echo "  -> $BACKUP_DIR/docker-compose-$TS.yml"

echo "✅ 备份完成: $BACKUP_DIR"
