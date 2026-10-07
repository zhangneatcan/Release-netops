#!/bin/bash
# 资产导入后置 is_managed=1，并重新编译采集计划
set -e
cd /opt/nexora-automation

# 1. 标记 is_managed
docker compose exec -T db psql -U postgres -d netops -c "
UPDATE devices SET is_managed = 1
WHERE status = 'online' AND platform IS NOT NULL AND platform != '' AND is_managed = 0;
"

# 2. 重新编译 collector 配置
docker compose exec -T netops python -c "
from api.monitoring_v1 import compile_collector, publish_collector, CompileRequest
from database import get_db_connection
cid = 'collector-local'
conn = get_db_connection()
row = conn.execute('SELECT MAX(config_version) AS v FROM monitoring_config_versions WHERE collector_id = ?', (cid,)).fetchone()
next_v = (row['v'] or 0) + 1
conn.close()
r1 = compile_collector(cid, body=CompileRequest(config_version=next_v))
print('compile:', r1.get('status'))
r2 = publish_collector(cid)
print('publish:', r2.get('status'))
"

echo "✅ 资产导入后处理完成"
