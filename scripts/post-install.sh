#!/bin/bash
# scripts/post-install.sh
#
# 用途：从上游拉新代码、重建容器后，恢复所有数据库层面的定制。
# 这些定制无法通过 git 传递，必须每次重建后重新执行。
#
# 涵盖：
#   1. devices.is_managed = 1 （让所有在线设备出现在 UI）
#   2. monitoring_collection_plans.config_json 的 scrape_timeout / interval
#   3. 强制重新编译 collector 配置并发布
#
# 用法：
#   cd /opt/nexora-automation
#   ./scripts/post-install.sh

set -euo pipefail

cd "$(dirname "$0")/.."
echo "======================================"
echo " Nexora 升级后配置恢复"
echo " 目录: $(pwd)"
echo " 时间: $(date '+%Y-%m-%d %H:%M:%S')"
echo "======================================"

# ═══════════════════════════════════════════════════════════
# 0. 前置检查
# ═══════════════════════════════════════════════════════════
echo ""
echo ">>> [0/4] 前置检查"

if ! docker compose ps --services --filter "status=running" | grep -q "^netops$"; then
    echo "❌ netops 容器未运行，请先执行 docker compose up -d"
    exit 1
fi

if ! docker compose ps --services --filter "status=running" | grep -q "^db$"; then
    echo "❌ db 容器未运行，请先执行 docker compose up -d"
    exit 1
fi

echo "✅ netops 和 db 容器都在运行"

# ═══════════════════════════════════════════════════════════
# 1. 标记 is_managed = 1
# ═══════════════════════════════════════════════════════════
echo ""
echo ">>> [1/4] 标记所有在线设备 is_managed=1"

docker compose exec -T db psql -U postgres -d netops << 'SQL'
UPDATE devices
SET is_managed = 1
WHERE status = 'online'
  AND platform IS NOT NULL
  AND platform != ''
  AND is_managed = 0;

SELECT
    COUNT(*) FILTER (WHERE is_managed = 1 AND status = 'online') AS managed_online,
    COUNT(*) FILTER (WHERE is_managed = 0 AND status = 'online') AS unmanaged_online,
    COUNT(*) AS total
FROM devices;
SQL

# ═══════════════════════════════════════════════════════════
# 2. 修正 plan 的 scrape_timeout / interval
# ═══════════════════════════════════════════════════════════
echo ""
echo ">>> [2/4] 修正 monitoring_collection_plans.config_json"

docker compose exec -T netops python << 'PYEOF'
import json
import datetime
from database import get_db_connection

TARGET_TIMEOUT = "60s"
TARGET_INTERVAL = "300s"

conn = get_db_connection()
now = datetime.datetime.now(datetime.timezone.utc).replace(microsecond=0).isoformat()

rows = conn.execute(
    "SELECT id, name, config_json FROM monitoring_collection_plans WHERE enabled = 1"
).fetchall()

updated = 0
for row in rows:
    plan_id = row["id"]
    try:
        config = json.loads(row["config_json"] or "{}")
    except (TypeError, ValueError):
        print(f"  跳过 {plan_id}: config_json 非法")
        continue
    modules = config.get("modules") or []
    if not isinstance(modules, list):
        continue
    changed = False
    for entry in modules:
        if not isinstance(entry, dict) or entry.get("enabled", True) is False:
            continue
        if str(entry.get("scrape_timeout")) != TARGET_TIMEOUT:
            entry["scrape_timeout"] = TARGET_TIMEOUT
            changed = True
        if str(entry.get("interval")) != TARGET_INTERVAL:
            entry["interval"] = TARGET_INTERVAL
            changed = True
    if changed:
        conn.execute(
            "UPDATE monitoring_collection_plans SET config_json = ?, updated_at = ? WHERE id = ?",
            (json.dumps(config, ensure_ascii=False), now, plan_id),
        )
        print(f"  已更新 plan: {plan_id} ({row['name']})")
        updated += 1

conn.commit()
conn.close()
print(f"  共更新 {updated} 个 plan")
PYEOF

# ═══════════════════════════════════════════════════════════
# 3. 强制重新编译 collector 配置并发布
# ═══════════════════════════════════════════════════════════
echo ""
echo ">>> [3/4] 强制重新编译 collector 配置"

docker compose exec -T netops python << 'PYEOF'
from api.monitoring_v1 import compile_collector, publish_collector, CompileRequest
from database import get_db_connection

cid = "collector-local"

conn = get_db_connection()
row = conn.execute(
    "SELECT MAX(config_version) AS v FROM monitoring_config_versions WHERE collector_id = ?",
    (cid,),
).fetchone()
next_v = (row["v"] or 0) + 1
conn.close()

r1 = compile_collector(cid, body=CompileRequest(config_version=next_v))
print(f"  compile: status={r1.get('status')} version={r1.get('config_version')}")

r2 = publish_collector(cid)
print(f"  publish: status={r2.get('status')} reload={r2.get('snmp_exporter_reload')}")
PYEOF

# ═══════════════════════════════════════════════════════════
# 4. 验证
# ═══════════════════════════════════════════════════════════
echo ""
echo ">>> [4/4] 验证"

docker compose exec -T vmagent sh -c '
    grep "nexora_scrape_timeout\|nexora_scrape_interval" \
        /etc/nexora-collector/runtime/vmagent/targets/snmp_targets.yml \
        | sort | uniq -c
' || echo "  ⚠️  无法读取 vmagent 配置（可能路径不同，不影响）"

echo ""
echo "======================================"
echo " ✅ 恢复完成"
echo "======================================"
echo ""
echo "如果 UI 还是显示旧数据，请："
echo "  1. 浏览器按 Ctrl+Shift+R 强刷"
echo "  2. 或清浏览器缓存后重登录"
echo ""
