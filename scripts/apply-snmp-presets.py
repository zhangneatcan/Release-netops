#!/usr/bin/env python3
"""
scripts/apply-snmp-presets.py

用途：
  把 Nexora 内置的 23 个官方 SNMP 预设物化，并绑定到匹配的设备。
  解决 device_collection_status 中 template_required 报错的问题。

幂等性：
  - 物化：已存在的 preset 会更新（applied_mode=updated）
  - 绑定：已绑定到相同 profile 的设备会跳过
  - 无匹配预设的设备会跳过（不报错）

用法（在 nexora-netops 容器内执行）：
  docker compose exec -T netops python /app/scripts/apply-snmp-presets.py
"""
from __future__ import annotations

import logging
import sys
from collections import Counter, defaultdict

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(message)s",
)
log = logging.getLogger("apply-snmp-presets")

# ═══════════════════════════════════════════════════════════════
# 依赖导入（必须在容器内执行）
# ═══════════════════════════════════════════════════════════════
try:
    from database import get_db_connection
    from services.snmp_preset_service import list_preset_profiles, match_profile_for_model
    from services.snmp_metric_profile_service import (
        apply_official_model_preset,
        bind_model_metric_profile,
    )
except ImportError as exc:
    log.error("必须在 nexora-netops 容器内执行：%s", exc)
    sys.exit(1)


def materialize_all_presets(conn) -> dict[str, dict]:
    """物化所有可测试的官方预设，返回 preset_id -> profile 字典。"""
    presets = list_preset_profiles()
    log.info("官方预设总数: %d", len(presets))

    profiles_by_preset: dict[str, dict] = {}
    materialized = 0
    skipped = 0

    for preset in presets:
        preset_id = str(preset.get("id") or "").strip()
        if not preset_id:
            continue
        # 不可测试的预设（testable=False）或无 metric_definitions 的跳过
        if preset.get("testable") is False:
            log.warning("跳过不可测试的预设: %s (%s %s)",
                        preset_id, preset.get("vendor"), preset.get("model"))
            skipped += 1
            continue
        if not preset.get("metric_definitions"):
            log.warning("跳过无指标定义的预设: %s", preset_id)
            skipped += 1
            continue

        try:
            profile = apply_official_model_preset(
                conn, preset_id, updated_by="apply-snmp-presets",
            )
            profiles_by_preset[preset_id] = profile
            materialized += 1
            log.info(
                "  [%s] %s %s -> profile_id=%s",
                profile.get("applied_mode", "?"),
                preset.get("vendor"),
                preset.get("model"),
                profile.get("id"),
            )
        except Exception as exc:
            log.warning("物化预设失败 %s: %s", preset_id, exc)
            skipped += 1

    conn.commit()
    log.info("物化完成: %d 成功, %d 跳过", materialized, skipped)
    return profiles_by_preset


def bind_devices(conn, profiles_by_preset: dict[str, dict]) -> None:
    """遍历在线设备，按 vendor+model 匹配预设，批量绑定。"""
    devices = conn.execute("""
        SELECT id, hostname, vendor, model, platform, snmp_metric_profile_id
        FROM devices
        WHERE status = 'online'
          AND platform IS NOT NULL AND platform != ''
    """).fetchall()
    log.info("在线设备总数: %d", len(devices))

    # 按 preset_id 分组：把匹配同一预设的设备 id 收集起来，一次批量绑定
    devices_by_preset: dict[str, list[str]] = defaultdict(list)
    no_match = Counter()
    already_bound = 0

    for d in devices:
        d = dict(d)
        device_id = str(d.get("id") or "")
        vendor = str(d.get("vendor") or "").strip()
        model = str(d.get("model") or "").strip()

        if not device_id:
            continue
        if not vendor or not model:
            no_match[f"{vendor or '?'}/{'?'}"] += 1
            continue

        # 已是绑定状态就跳过（幂等）
        existing_profile_id = str(d.get("snmp_metric_profile_id") or "").strip()
        if existing_profile_id:
            already_bound += 1
            continue

        preset = match_profile_for_model(vendor, model)
        if not preset:
            no_match[f"{vendor}/{model}"] += 1
            continue

        preset_id = str(preset.get("id") or "").strip()
        if preset_id not in profiles_by_preset:
            no_match[f"{vendor}/{model}"] += 1
            continue

        profile = profiles_by_preset[preset_id]
        profile_id = str(profile.get("id") or "")
        if not profile_id:
            continue
        devices_by_preset[profile_id].append(device_id)

    # 批量绑定
    log.info("准备绑定:")
    bound_total = 0
    failed_total = 0
    for profile_id, device_ids in devices_by_preset.items():
        try:
            result = bind_model_metric_profile(conn, profile_id, device_ids)
            bound_total += len(device_ids)
            log.info("  profile_id=%s 绑定 %d 台设备",
                     profile_id, len(device_ids))
        except Exception as exc:
            failed_total += len(device_ids)
            log.error("  profile_id=%s 绑定失败: %s", profile_id, exc)
    conn.commit()

    log.info("绑定完成: 成功 %d 台, 失败 %d 台", bound_total, failed_total)
    if already_bound:
        log.info("已绑定的设备: %d 台（跳过）", already_bound)
    if no_match:
        log.info("无匹配预设的设备（按 vendor/model）:")
        for key, count in no_match.most_common():
            log.info("  %s: %d 台", key, count)


def main() -> int:
    conn = get_db_connection()
    try:
        log.info("═" * 60)
        log.info("步骤 1: 物化官方预设")
        log.info("═" * 60)
        profiles_by_preset = materialize_all_presets(conn)

        log.info("")
        log.info("═" * 60)
        log.info("步骤 2: 批量绑定到设备")
        log.info("═" * 60)
        bind_devices(conn, profiles_by_preset)

        log.info("")
        log.info("═" * 60)
        log.info("完成")
        log.info("═" * 60)
        return 0
    except Exception as exc:
        log.exception("执行失败: %s", exc)
        try:
            conn.rollback()
        except Exception:
            pass
        return 1
    finally:
        conn.close()


if __name__ == "__main__":
    sys.exit(main())
