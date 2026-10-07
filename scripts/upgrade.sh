#!/bin/bash
# 从上游拉新版本 → 合并 → 重建 → 恢复数据库定制
set -euo pipefail
cd "$(dirname "$0")/.."

echo "======================================"
echo " Nexora 升级"
echo " 时间: $(date '+%Y-%m-%d %H:%M:%S')"
echo "======================================"

# 0. 备份
echo ""
echo ">>> [0/5] 备份数据库"
mkdir -p /opt/nexora-backups
docker compose exec -T db pg_dump -U postgres -d netops > /opt/nexora-backups/db-$(date +%Y%m%d_%H%M).sql
echo "  -> /opt/nexora-backups/db-$(date +%Y%m%d_%H%M).sql"

# 1. 拉上游
echo ""
echo ">>> [1/5] 拉取上游最新"
git fetch upstream
echo "  上游最新: $(git log upstream/main --oneline -1)"

# 2. 合并
echo ""
echo ">>> [2/5] 合并上游到本地"
if ! git merge upstream/main --no-edit; then
    echo ""
    echo "❌ 合并冲突，需要手动解决："
    echo "   冲突文件:"
    git diff --name-only --diff-filter=U
    echo ""
    echo "   解决步骤:"
    echo "   1. vi <冲突文件>          # 保留本地修复 + 上游新功能"
    echo "   2. git add -A"
    echo "   3. git commit -m 'merge: 保留本地修复'"
    echo "   4. 重新运行 ./scripts/upgrade.sh"
    exit 1
fi
echo "✅ 合并成功"

# 3. 推送
echo ""
echo ">>> [3/5] 推送到 mine 仓库"
git push mine main

# 4. 重建
echo ""
echo ">>> [4/5] 重建 netops 并启动"
docker compose build netops
docker compose up -d
echo "  等待 netops 健康..."
until [ "$(docker inspect -f '{{.State.Health.Status}}' nexora-netops 2>/dev/null)" = "healthy" ]; do
    sleep 5
    echo -n "."
done
echo ""
echo "✅ netops healthy"

# 5. 恢复数据库定制
echo ""
echo ">>> [5/5] 恢复数据库定制"
./scripts/post-install.sh

echo ""
echo "======================================"
echo " ✅ 升级完成"
echo "======================================"
