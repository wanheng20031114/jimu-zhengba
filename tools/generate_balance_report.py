"""Export live Godot combat arithmetic and render a reproducible Chinese audit.

The Python renderer deliberately does not implement damage resolution. All damage,
armor, HP and hit counts come from DamageResolver through export_balance_report.gd.
"""

from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path
import shutil
import subprocess
import sys
from typing import Any

ROOT = Path(__file__).resolve().parents[1]
BASELINE_REF = "1798390"
LEVELS = ("0", "I", "II", "III")
CLASSES = {"infantry": "剑士", "archer": "弓箭手", "cavalry": "骑兵", "siege": "攻城器", "building": "建筑", "worker": "农民"}


def number(value: float | int) -> str:
    return f"{value:.3f}".rstrip("0").rstrip(".") if value != int(value) else str(int(value))


def table(headers: list[str], rows: list[list[Any]]) -> str:
    return "\n".join([
        "| " + " | ".join(headers) + " |",
        "| " + " | ".join("---" for _ in headers) + " |",
        *("| " + " | ".join(str(cell) for cell in row) + " |" for row in rows),
    ])


def cell(row: dict[str, Any]) -> str:
    return f"{number(row['damage'])} / **{row['hits']}** / {number(row['seconds_after_first_hit'])}"


def source_hashes() -> dict[str, str]:
    files = sorted((ROOT / "data/units").glob("*.tres"))
    files += sorted((ROOT / "data/buildings").glob("*.tres"))
    files += sorted((ROOT / "data/upgrades").glob("*.tres"))
    files += [ROOT / path for path in (
        "data/economy.tres", "scripts/data/economy_definition.gd",
        "scripts/battle_unit.gd", "scripts/resource_vein.gd",
        "scripts/player_state.gd", "scripts/combat/damage_resolver.gd",
        "scripts/projectile.gd", "tests/catapult_impact_test.gd",
        "scripts/data/combat_definition.gd", "scripts/data/balance_catalog.gd",
        "tools/export_balance_report.gd", "tools/generate_balance_report.py",
    )]
    return {file.relative_to(ROOT).as_posix(): hashlib.sha256(file.read_bytes()).hexdigest() for file in files}


def prepare_baseline(work: Path) -> tuple[str, dict[str, str], str]:
    """Retrieve historical resource bytes; Godot, rather than Python, reads them."""
    commit = subprocess.run(["git", "rev-parse", BASELINE_REF], cwd=ROOT, capture_output=True, check=True, text=True).stdout.strip()
    destination = work / "baseline"
    destination.mkdir(parents=True, exist_ok=True)
    hashes: dict[str, str] = {}
    resources = [f"data/units/{kind}.tres" for kind in ("swordsman", "archer", "knight", "catapult", "cannon", "farmer")]
    resources += [f"data/upgrades/{track}_{level}.tres" for track in ("attack", "defense") for level in range(1, 4)]
    for resource in resources:
        content = subprocess.run(["git", "show", f"{commit}:{resource}"], cwd=ROOT, capture_output=True, check=True).stdout
        (destination / Path(resource).name).write_bytes(content)
        hashes[resource] = hashlib.sha256(content).hexdigest()
    # Run the historical resolver too: the current API intentionally removes
    # falloff, while the historical script retains its own exact arithmetic.
    resolver = "scripts/combat/damage_resolver.gd"
    old = subprocess.run(["git", "show", f"{commit}:{resolver}"], cwd=ROOT, capture_output=True, check=True).stdout
    hashes[resolver] = hashlib.sha256(old).hexdigest()
    # Removing its global class registration avoids colliding with the live
    # DamageResolver; all method bodies and historical data remain untouched.
    (destination / "historical_damage_resolver.gd").write_bytes(old.replace(b"class_name DamageResolver\n", b"", 1))
    return commit, hashes, "res://" + destination.relative_to(ROOT).as_posix()


def validate(data: dict[str, Any], final: bool) -> dict[str, Any]:
    failures: list[str] = []
    checks = 0

    def check(ok: bool, label: str) -> None:
        nonlocal checks
        checks += 1
        if not ok:
            failures.append(label)

    units = {u["id"]: u for u in data["units"]}
    matchups = {(r["attacker"], r["defender"], r["attack_level"], r["defense_level"]): r for r in data["matchups"]}
    check(len(matchups) == len(units) ** 2 * 16 == len(data["matchups"]), "每种单位组合恰有16个无重复的攻防科技组合")
    for group in ("matchups", "building_matchups", "defense_matchups"):
        for row in data[group]:
            label = f"{group}: {row['attacker']}→{row['defender']} A{row['attack_level']} D{row['defense_level']}"
            check(row["damage"] >= 1, label + " 最低1点伤害")
            check(row["hits"] >= 1 and row["damage"] * row["hits"] >= row["target_hp"] - 1e-6 and row["remaining_after_penultimate_hit"] > 0, label + " 致死命中边界正确")
            check(row["seconds_after_first_hit"] >= 0, label + " 首次命中后的理论时间非负")
    for attacker in units:
        for defender in units:
            for level in range(1, 4):
                attack = matchups[attacker, defender, level, 0]
                previous = matchups[attacker, defender, level - 1, 0]
                check(attack["damage"] >= previous["damage"] and attack["hits"] <= previous["hits"], f"{attacker}→{defender} 攻击升级{level}不会减弱")
                defense = matchups[attacker, defender, 0, level]
                previous = matchups[attacker, defender, 0, level - 1]
                check(defense["damage"] <= previous["damage"] and defense["hits"] >= previous["hits"], f"{attacker}→{defender} 防御升级{level}不会减弱")
            if not units[attacker]["military"]:
                check(all(matchups[attacker, defender, level, 0]["damage"] == matchups[attacker, defender, 0, 0]["damage"] for level in range(4)), f"{attacker} 不享军事攻击科技")
            if not units[defender]["military"]:
                check(all(matchups[attacker, defender, 0, level]["damage"] == matchups[attacker, defender, 0, 0]["damage"] for level in range(4)), f"{defender} 不享军事防御科技")
    for track, bonuses in (("attack", data["attack_bonuses"]), ("defense", data["defense_bonuses"])):
        for upgrade in (u for u in data["upgrades"] if u["track"] == track):
            check(upgrade["total_bonus"] == bonuses[upgrade["level"]], f"{upgrade['id']}资源总加成与PlayerState实际加成一致")
    # Historical exports predate these independent economy tracks. Their combat
    # rows and baseline evidence can still be rendered without inventing values.
    if "economy" in data:
        economy = data["economy"]
        capacities = {row["level"]: row for row in economy["military_capacity_levels"]}
        mining = {row["level"]: row for row in economy["mining_levels"]}
        upgrades = {row["id"]: row for row in data["upgrades"]}
        check(set(capacities) == {0, 1, 2}, "军队扩编导出零至二级实际人口上限")
        check(set(mining) == {0, 1, 2, 3}, "采矿效率导出零至三级实际效率")
        check(economy["passive_gold_per_second"] == 1, "自然收入保留每秒一金币")
        check(economy["mining_gold_per_cycle"] == 4 and economy["mining_base_seconds"] == 3, "基础采矿仍为三秒四金币")
        check(economy["mine_capacity"] == 6, "单矿保留六个实际采矿槽")
        check([row["worker_limit"] for row in sorted(economy["worker_limits"], key=lambda row: row["level"])] == [10, 12],
              "农民上限独立于军队扩编保持十至十二人")
        for level, row in capacities.items():
            check(row["military_supply_limit"] == 50 + 25 * level, f"军队扩编{level}实际人口上限为{50 + 25 * level}")
            if level:
                upgrade = upgrades[f"army_capacity_{level}"]
                check(upgrade["cost"] == 500 and upgrade["total_bonus"] == row["military_supply_limit"] - capacities[0]["military_supply_limit"],
                      f"军队扩编{level}资源成本五百及累计效果与PlayerState一致")
        for level, row in mining.items():
            check(abs(row["rate_multiplier"] - (1 + 0.1 * level)) < 1e-8, f"采矿{level}为累计百分比而非复利")
            check(abs(row["cycle_seconds"] * row["rate_multiplier"] - economy["mining_base_seconds"]) < 1e-8,
                  f"采矿{level}实际效率正确缩短基础周期")
            check(abs(row["farmer_gold_per_minute"] - (80 + 8 * level)) < 1e-6, f"采矿{level}每农民每分钟金币符合实际倍率")
            check(row["full_workers"] == 12 and abs(row["full_economy_gold_per_minute"] - (80 + 8 * level) * 12 - 60) < 1e-6,
                  f"采矿{level}十二农民加自然收入计算正确")
            check(abs(row["full_economy_gold_per_second"] * 60 - row["full_economy_gold_per_minute"]) < 1e-6,
                  f"采矿{level}秒与分钟收入一致")
            if level:
                upgrade = upgrades[f"mining_{level}"]
                check(upgrade["cost"] == (50, 150, 300)[level - 1] and abs(upgrade["total_bonus"] / 100 + 1 - row["rate_multiplier"]) < 1e-8,
                      f"采矿{level}资源成本及累计效果与PlayerState一致")
    if final:
        base = lambda a, d: matchups[a, d, 0, 0]
        check(base("cannon", "cannon")["hits"] == 5, "无科技加农炮五击摧毁同款")
        for defender in ("swordsman", "archer", "knight"):
            check(base("catapult", defender)["hits"] >= 4, f"投石车至少四次命中击杀{defender}")
        for defender in ("swordsman", "archer"):
            for attack_level in range(4):
                for defense_level in range(4):
                    check(matchups["catapult", defender, attack_level, defense_level]["hits"] >= 4, f"投石车A{attack_level}/D{defense_level}至少四次命中击杀{defender}")
        for level in range(4):
            check(matchups["cannon", "cannon", level, level]["hits"] == 5, f"同级科技{level}加农炮五击摧毁同款")
        if "impact_validation" in data:
            impact = data["impact_validation"]
            check(impact["build_id"] == data["build_id"], "真实投石日志来自相同游戏版本")
            check(not impact["failures"], "真实投石落点专项检查通过")
            samples = {sample["label"]: sample for sample in impact["uniform_splash_samples"]}
            check(all(label in samples for label in ("center", "inner", "edge", "outside", "friendly", "edge_siege", "edge_building")), "真实投石包含中心、内圈、边缘、范围外、友军及建筑攻城器样本")
            for sample in samples.values():
                check(abs(sample["actual"] - sample["expected"]) < 1e-5, f"真实投石{sample['label']}符合预期伤害")
                if sample["label"] in ("outside", "friendly"):
                    current_damage = 0
                elif sample["target"] in units:
                    current_damage = base("catapult", sample["target"])["damage"]
                else:
                    current_damage = next(row for row in data["building_matchups"] if row["attacker"] == "catapult" and row["defender"] == sample["target"] and row["attack_level"] == 0)["damage"]
                check(abs(sample["actual"] - current_damage) < 1e-5, f"真实投石{sample['label']}与当前导出资源伤害一致")
            if all(label in samples for label in ("center", "inner", "edge")):
                check(samples["center"]["actual"] == samples["inner"]["actual"] == samples["edge"]["actual"], "真实投石相同目标在中心与边缘同伤")
        check(units["farmer"]["hp"] == 150, "农民生命翻倍至150")
        check(units["swordsman"]["ranged_armor"] == 0, "剑士远程护甲为0")
        check(units["archer"]["ranged_armor"] > 0, "弓手具有远程护甲")
        check(units["knight"]["ranged_armor"] > 0, "骑兵具有远程护甲")
    return {"checks": checks, "failures": failures, "final_requirements_checked": final}


def render_economy(data: dict[str, Any]) -> list[str]:
    """Only render recorded authority data; older JSON has no economy section."""
    if "economy" not in data:
        return []
    economy = data["economy"]
    capacity = {row["level"]: row for row in economy["military_capacity_levels"]}
    mining = {row["level"]: row for row in economy["mining_levels"]}
    rows = []
    for track in ("army_capacity", "mining"):
        cost = 0
        seconds = 0
        for upgrade in sorted((u for u in data["upgrades"] if u["track"] == track), key=lambda u: u["level"]):
            cost += upgrade["cost"]
            seconds += upgrade["research_seconds"]
            level = upgrade["level"]
            effect = (f"军事人口 {capacity[level]['military_supply_limit']}（总计 +{upgrade['total_bonus']}）" if track == "army_capacity" else
                      f"采矿效率 +{upgrade['total_bonus']}%（倍率 ×{number(mining[level]['rate_multiplier'])}）")
            rows.append([upgrade["name"], upgrade["cost"], number(upgrade["research_seconds"]), effect, cost, number(seconds)])
    parts = ["## 军队扩编与采矿效率科技", "",
        "两条新路线均在学院依次研究，与军事攻防和农民上限扩展独立。下表为新增的五项升级；费用与时长从实际科技资源读取，完成效果从 `PlayerState` 导出。", "",
        table(["科技", "本级金币", "本级秒数", "完成后的累计效果", "本路线累计金币", "本路线累计秒数"], rows), "",
        "军事人口上限为 **50 → 75 → 100**，每级新增 25 人口、各花费 500 金币；存活部队与生产队列预留人口共用上限。这里是人口点数：剑士、弓手各占 1，骑士占 2，攻城器占 3。农民仍使用独立的 10 人上限，完成农民上限扩展后为 12 人。", "",
        "### 采矿速度与经济收益", "",
        f"基础采矿每 {number(economy['mining_base_seconds'])} 秒结算 {economy['mining_gold_per_cycle']} 金币；科技提高工作进度推进速度，累计效果为 **+10% / +20% / +30%**，对应 ×1.1 / ×1.2 / ×1.3，不进行逐级复利。每次结算的金币数量保持不变。", "",
        table(["采矿等级", "速度倍率", "实际倍率对应周期／秒", "每农民金币／分钟", "12 农民＋自然金币／分钟", "12 农民＋自然金币／秒"], [
            [LEVELS[level], "×" + number(row["rate_multiplier"]), number(row["cycle_seconds"]),
             number(row["farmer_gold_per_minute"]), number(row["full_economy_gold_per_minute"]),
             number(row["full_economy_gold_per_second"])] for level, row in sorted(mining.items())]), "",
        f"自然收入保持 **每秒 {number(economy['passive_gold_per_second'])} 金币**，不受采矿科技影响。单矿最多提供 {economy['mine_capacity']} 个采集位置，12 农民满效率至少需要两处矿脉及足够的实际采矿位置。", "",
        "研究完成时保留当前已完成的采矿进度，只有剩余工作从下一逻辑步开始按新速度推进；不重置进度，也不回溯增加已结算的金币。改变单位命令等原有工作中断规则保持独立。", "",
        "表内收入是持续采矿的长期速率，周期由实际 `PlayerState` 倍率与经济资源计算，不计走向矿脉、等待空位或受袭停工。游戏以 30 TPS 推进并按整次周期发放金币，因此任意截取一分钟的实际到账会受起始进度与结算时刻影响，不能保证每个短时间窗口都恰好等于平均值。", ""]
    return parts


def render(data: dict[str, Any]) -> str:
    units = data["units"]
    names = {u["id"]: u["name"] for u in units + data["buildings"]}
    lookup = {(r["attacker"], r["defender"], r["attack_level"], r["defense_level"]): r for r in data["matchups"]}
    building_lookup = {(r["attacker"], r["defender"], r["attack_level"]): r for r in data["building_matchups"]}
    parts = [f"# 灰烬王国 {data['build_id']} 战斗数值完整审查", "",
        "本报告由实际 Godot 资源、玩家科技状态和 `DamageResolver` 导出。Python 负责排版与命中边界校验，不另写伤害公式。对应机器数据与完整资源 SHA-256 位于同目录 JSON，可复现核对。", "",
        "## 计算口径", "",
        "- 全部对象满血、敌对、每次有效命中；不计多人集火、移动、躲避、阻挡、最小射程、动画前摇、弹丸飞行或治疗。",
        "- 表格每格均为 **单次实际伤害 / 击杀所需命中次数 / 首次命中后的理论秒数**。时间以第一下命中为 0，即 `(命中次数 − 1) × 攻击间隔`；它不是从下令开始计算的实战击杀时间。",
        "- 攻击科技与目标防御科技分别取 0、I、II、III；等级是研究后的总效果，不逐级相加。36 张完整表包括双方科技不一致的全部 576 种组合。",
        "- 农民和建筑不受军事攻防科技影响。攻城器始终没有近战护甲，军事防御科技只增加它们的远程护甲。防御图标代表护甲，不存在独立吸收伤害或自动恢复的护盾条。",
        "- 伤害下限为 1；类型附伤按目标战斗类别取一项。箭矢、投石和炮弹使用远程护甲。科技计入出手伤害快照，命中时读取目标当前防御。",
        "- 所有矩阵只衡量单个攻击者，不代表同成本兵力或不同地形下的实际胜率。", "",
        "## 本版硬指标与兵种分工", ""]
    key_pairs = [("cannon", "cannon"), ("catapult", "swordsman"), ("catapult", "archer"), ("catapult", "knight"),
                 ("knight", "archer"), ("archer", "swordsman"), ("swordsman", "knight")]
    parts.append(table(["无科技攻击者 → 目标", "实际伤害", "命中次数", "首次命中后秒数"], [
        [f"{names[a]} → {names[d]}", number(lookup[a, d, 0, 0]["damage"]), lookup[a, d, 0, 0]["hits"], number(lookup[a, d, 0, 0]["seconds_after_first_hit"])] for a, d in key_pairs]))
    parts += ["", "骑兵依靠机动、对弓手附伤和远程护甲切后排；弓箭手利用射程和齐射压制零远程护甲的剑士；剑士依靠对骑兵附伤守住阵线。延长交战仍需依靠站位与兵种配合，不能把命中次数表当作一对一必胜结论。", ""]
    if "baseline" in data:
        baseline = data["baseline"]
        old_units = {u["id"]: u for u in baseline["units"]}
        old_lookup = {(r["attacker"], r["defender"]): r for r in baseline["matchups"]}
        parts += ["### 与 0.8.0 的实际变化", "",
            f"旧资源及旧版 `DamageResolver` 取自公开仓库提交 `{baseline['source_commit']}`，由 Godot 加载历史定义与历史结算方法重算。这里只比较双方无科技、投石直接命中中心的情况，不把旧版边缘衰减混入新数值对比。", "",
            table(["单位", "旧生命 → 新生命", "生命倍率", "旧基础攻击 → 新基础攻击", "旧近甲 / 远甲 → 新近甲 / 远甲"], [
                [u["name"], f"{number(old_units[u['id']]['hp'])} → {number(u['hp'])}", f"{u['hp'] / old_units[u['id']]['hp']:.2f}×",
                 f"{number(old_units[u['id']]['damage'])} → {number(u['damage'])}",
                 f"{number(old_units[u['id']]['melee_armor'])}/{number(old_units[u['id']]['ranged_armor'])} → {number(u['melee_armor'])}/{number(u['ranged_armor'])}"] for u in units]), "",
            "以下每格为 **旧版命中次数 → 新版命中次数**，涵盖全部无科技单位对位。", "",
            table(["攻击者 ↓ / 目标 →", *[u["name"] for u in units]], [
                [a["name"], *[f"{old_lookup[a['id'], d['id']]['hits']} → **{lookup[a['id'], d['id'], 0, 0]['hits']}**" for d in units]] for a in units]), "",
            table(["攻击者 → 目标", "旧版首击后秒数", "新版首击后秒数", "变化"], [
                [f"{names[a]} → {names[d]}", number(old_lookup[a, d]["seconds_after_first_hit"]), number(lookup[a, d, 0, 0]["seconds_after_first_hit"]),
                 f"+{number(lookup[a, d, 0, 0]['seconds_after_first_hit'] - old_lookup[a, d]['seconds_after_first_hit'])} 秒"] for a, d in key_pairs]), "",
            "比较应以实际伤害、命中次数和时间为准：提升耐久可以来自减少攻击或调整护甲，不能只看生命条大小，也不能假设每个对位都延长相同比例。价格、人口、生产时间和攻击间隔保持原值。", ""]
        unchanged_military_hp = all(u["hp"] == old_units[u["id"]]["hp"] for u in units if u["military"])
        if unchanged_military_hp:
            parts += ["本版军事单位生命沿用 0.8.0，通过降低基础伤害、重排类别附伤和小整数护甲延长战斗；农民生命单独翻倍。", ""]
        parts += ["弓箭手的基础攻击也降低了，但降幅小于两种近战军事单位；与剑士远程护甲归零共同形成更强的相对克制，不表示弓手的绝对攻击高于旧版。", "",
            table(["单位", "旧基础攻击", "新基础攻击", "基础攻击变化"], [
                [names[kind], number(old_units[kind]["damage"]), number(next(u for u in units if u["id"] == kind)["damage"]),
                 f"{(next(u for u in units if u['id'] == kind)['damage'] / old_units[kind]['damage'] - 1) * 100:+.1f}%"]
                for kind in ("swordsman", "archer", "knight")]), ""]
        quicker, same, longer = [], [], []
        for a in units:
            for d in units:
                pair = (a["id"], d["id"])
                old_time = old_lookup[pair]["seconds_after_first_hit"]
                new_time = lookup[pair[0], pair[1], 0, 0]["seconds_after_first_hit"]
                (quicker if new_time < old_time - 1e-5 else longer if new_time > old_time + 1e-5 else same).append(pair)
        parts += [f"全部 36 个无科技单对位中：{len(longer)} 个理论击杀时间延长，{len(same)} 个持平，{len(quicker)} 个缩短。农民、同类与攻城器组合均计入；此统计不包括多单位集火。", ""]
        if quicker:
            parts += ["缩短的具体对位：" + "、".join(f"{names[a]} → {names[d]}" for a, d in quicker) + "。这属于单独调整后的真实结果，不应宣称所有对位都变慢。", ""]
    parts += [
        "投石车保留半径 3 的无友伤范围攻击，命中区域内使用相同伤害，不再按距离衰减。投石落点在发射时确定，仍然可以通过走位躲开。静态数值导出不模拟弹丸落点，实际范围、边缘伤害和友军过滤由 `tests/catapult_impact_test.gd` 的真实场景专测验证。", "",
        "## 单位基础资源", ""]
    parts.append(table(["单位", "金币", "人口", "生命", "近甲 / 远甲", "攻击 / 类型", "类别附伤", "间隔", "射程 / 最小", "移速", "训练秒"], [
        [u["name"], u["cost"], u["supply"] if u["military"] else "独立农民名额", number(u["hp"]),
         f"{number(u['melee_armor'])} / {number(u['ranged_armor'])}", f"{number(u['damage'])} / {'近战' if u['damage_channel'] == 'melee' else '远程'}",
         "、".join(f"{CLASSES.get(k, k)} +{number(v)}" for k, v in u["bonuses"].items()) or "无",
         number(u["cooldown"]), f"{number(u['range'])} / {number(u['min_range'])}", number(u["speed"]), number(u["training_seconds"])] for u in units]))
    parts += ["", "## 军事科技效果、费用与实用性", "",
        "攻击与防御分别计算总加成。前一级研究完成后才能研究下一级；表中累计费用和累计研究时间是单条路线从零开始的总投入，多学院并行不同路线可以缩短总等待。", ""]
    upgrade_rows: list[list[Any]] = []
    for track, title in (("attack", "攻击"), ("defense", "防御")):
        cost = 0
        seconds = 0
        previous = 0
        for upgrade in (u for u in data["upgrades"] if u["track"] == track):
            cost += upgrade["cost"]
            seconds += upgrade["research_seconds"]
            upgrade_rows.append([title + " " + LEVELS[upgrade["level"]], "+" + str(upgrade["total_bonus"]),
                                 "+" + str(upgrade["total_bonus"] - previous), upgrade["cost"], number(upgrade["research_seconds"]), cost, number(seconds)])
            previous = upgrade["total_bonus"]
    parts.append(table(["科技", "完成后总加成", "本级新增", "本级金币", "本级秒数", "累计金币", "累计秒数"], upgrade_rows))
    if "baseline" in data:
        parts += ["", table(["路线", "旧版 I / II / III", "新版 I / II / III"], [
            [title, " / ".join("+" + str(v) for v in data["baseline"]["upgrade_bonuses"][track][1:]),
             " / ".join("+" + str(v) for v in data[track + "_bonuses"][1:])]
            for track, title in (("attack", "攻击"), ("defense", "防御"))]), "",
            "攻击与防御分别读取各自科技资源。伤害降低后，小整数攻击与护甲同样可能显著改变命中阈值，不能直接用面板加值大小判断科技是否有用；实际效果按下表核对。研究价格和时间保持原值。"]
    parts += ["", "**命中阈值检查。** 以下仅统计五类军事单位互相攻击的 25 种组合（含同类），以目标或攻击方无科技为基准，逐级比较完成本级研究前后的变化。不能减少击杀次数也可能提高残血收割和集火效率；不能增加承伤次数也可能增加剩余生命。", ""]
    military_ids = [u["id"] for u in units if u["military"]]
    effectiveness = []
    for level in range(1, 4):
        attack_changed = []
        defense_changed = []
        for a in military_ids:
            for d in military_ids:
                old = lookup[a, d, level - 1, 0]
                new = lookup[a, d, level, 0]
                if new["hits"] < old["hits"]:
                    attack_changed.append((a, d, old["hits"], new["hits"]))
                old = lookup[a, d, 0, level - 1]
                new = lookup[a, d, 0, level]
                if new["hits"] > old["hits"]:
                    defense_changed.append((a, d, old["hits"], new["hits"]))
        effectiveness.append([LEVELS[level], f"{len(attack_changed)} / 25", f"{len(defense_changed)} / 25"])
    parts.append(table(["本级研究", "攻击升级：减少命中次数的组合", "防御升级：增加承伤次数的组合"], effectiveness))
    parts += ["", "**一级科技的具体收益。** 这里以另一方没有对应科技为前提，直接比较升一级前后的真实结果。", "",
        table(["研究与交战", "升级前伤害 / 命中次数", "升级后伤害 / 命中次数", "效果"], [
            [f"攻击 I：{names[a]} → {names[d]}", f"{number(lookup[a, d, 0, 0]['damage'])} / {lookup[a, d, 0, 0]['hits']}",
             f"{number(lookup[a, d, 1, 0]['damage'])} / {lookup[a, d, 1, 0]['hits']}",
             f"实际 DPS +{(lookup[a, d, 1, 0]['damage'] / lookup[a, d, 0, 0]['damage'] - 1) * 100:.1f}%"]
            for a, d in (("swordsman", "swordsman"), ("archer", "knight"))] + [
            [f"目标防御 I：{names[a]} → {names[d]}", f"{number(lookup[a, d, 0, 0]['damage'])} / {lookup[a, d, 0, 0]['hits']}",
             f"{number(lookup[a, d, 0, 1]['damage'])} / {lookup[a, d, 0, 1]['hits']}",
             f"多承受 {lookup[a, d, 0, 1]['hits'] - lookup[a, d, 0, 0]['hits']} 次命中"]
            for a, d in (("knight", "archer"), ("catapult", "archer"))]), ""]
    parts += ["", "**三角克制的科技收益。** 攻击 III / 防御 0 用于衡量进攻方领先；攻击 0 / 防御 III 用于衡量防守方领先；同级 III 展示双方均满科技时的效果。", ""]
    triangle = [("knight", "archer"), ("archer", "swordsman"), ("swordsman", "knight"), ("cannon", "cannon"), ("catapult", "swordsman"), ("catapult", "archer")]
    parts.append(table(["攻击者 → 目标", "A0 / D0", "AIII / D0", "A0 / DIII", "AIII / DIII"], [
        [f"{names[a]} → {names[d]}", *(cell(lookup[a, d, al, dl]) for al, dl in ((0, 0), (3, 0), (0, 3), (3, 3)))] for a, d in triangle]))
    parts += ["", "**攻击 III 对无防御科技目标的实际 DPS 提升。** 下面展示百分比差异，防止只看面板固定加值而忽略低伤害兵种、重甲目标和类别附伤的差异。", ""]
    parts.append(table(["攻击者", *[names[d] for d in military_ids]], [
        [names[a], *[f"+{(lookup[a, d, 3, 0]['damage'] / lookup[a, d, 0, 0]['damage'] - 1) * 100:.1f}%" for d in military_ids]] for a in military_ids]))
    parts += ["", "科技为全军统一效果，同样研究费用覆盖的部队越多，总收益越高。固定加值对弓手等低单发兵种的相对提升更显著，对炮击建筑的相对提升更小；炮兵的主要收益仍是射程、单发火力和建筑附伤。攻城器不获得近战护甲，因此双方攻防同级时，骑兵和剑士打攻城器依然会随攻击科技增强。", "",
        "防御科技能够明显降低连续小额远程伤害，但需要花费金币并等待研究，不能替代肉盾和保护后排。它不增加生命上限，也不改变农民的生存数值。实际是否值得研究还受到场上兵力、扩军机会成本和正在面对的敌军影响。", "",
        "### 必须关注的极端值和限制", "",
        f"- 无科技剑士同类互砍：每刀 {number(lookup['swordsman', 'swordsman', 0, 0]['damage'])} 点，需要 {lookup['swordsman', 'swordsman', 0, 0]['hits']} 刀（首击后 {number(lookup['swordsman', 'swordsman', 0, 0]['seconds_after_first_hit'])} 秒）。基础近甲在低攻击下有很强影响，镜像步兵战应通过升级、弓手或投石支援破局。",
        f"- 无攻击科技弓手对防御 III 骑士：每箭 {number(lookup['archer', 'knight', 0, 3]['damage'])} 点，需 {lookup['archer', 'knight', 0, 3]['hits']} 箭。这是高远甲、科技差与兵种硬克制共同造成的极端值；弓手队伍应换用剑士保护并补攻击科技。",
        f"- 双方满科技且从贴身首次同时命中计算：弓手击杀剑士理论 {number(lookup['archer', 'swordsman', 3, 3]['seconds_after_first_hit'])} 秒，剑士击杀弓手理论 {number(lookup['swordsman', 'archer', 3, 3]['seconds_after_first_hit'])} 秒，相差 {number(abs(lookup['archer', 'swordsman', 3, 3]['seconds_after_first_hit'] - lookup['swordsman', 'archer', 3, 3]['seconds_after_first_hit']))} 秒。弓手对步兵的优势依赖射程先手、齐射与保持距离，不能宣称贴身互殴必胜。",
        f"- 无攻击科技炮对防御 III 炮需要 {lookup['cannon', 'cannon', 0, 3]['hits']} 炮；同级科技的五炮镜像不能解读成任何科技差下都固定五炮。",
        "- 全范围满伤提高了投石命中边缘时的威胁。单台需多次命中，不代表多台齐射密集部队也一定打得慢；散开和躲避仍然必要。",
        "- 延长单位存活会提高持续留场数量；它不会自动改善已有 432 单位极限场景的性能瓶颈。", ""]
    workforce = next(u for u in data["upgrades"] if u["track"] == "workforce")
    parts += [f"农民上限扩展保持独立经济科技：{workforce['cost']} 金币、{number(workforce['research_seconds'])} 秒、上限增加 {workforce['total_bonus']} 人；不计入以下军事攻防矩阵。", ""]
    parts += render_economy(data)
    parts += [
        "## 同级科技的完整 6 × 6 速查", "",
        "行是攻击者，列是目标。每格：伤害 / **命中次数** / 首次命中后秒数。", ""]
    for level in range(4):
        parts += [f"### 双方 {LEVELS[level]} 级", "", table(["攻击者 ↓ / 目标 →", *[u["name"] for u in units]], [
            [a["name"], *[cell(lookup[a["id"], d["id"], level, level]) for d in units]] for a in units]), ""]
    parts += ["## 全部单位的非对称科技组合", "", "每张表的行是攻击者攻击科技等级，列是目标防御科技等级。农民不享受军事科技，因此对应方向的重复数字是规则本身。", ""]
    for attacker in units:
        for defender in units:
            a, d = attacker["id"], defender["id"]
            parts += [f"### {names[a]} → {names[d]}", "", table(["攻击科技 ↓ / 防御科技 →", *LEVELS], [
                [LEVELS[al], *[cell(lookup[a, d, al, dl]) for dl in range(4)]] for al in range(4)]), ""]
    parts += ["## 建筑耐久与拆除效率", "", "本节列出所有可建造建筑，开局赠送的箭塔使用同一份防御塔数据。建筑没有军事防御科技；只需列出攻击方四级科技。工地未完工时的即时剩余生命取决于施工进度，本表统一采用完工满血建筑。", ""]
    parts.append(table(["建筑", "生命", "近甲 / 远甲", "成本", "建造秒", "攻击", "射程", "间隔"], [
        [b["name"], number(b["hp"]), f"{number(b['melee_armor'])} / {number(b['ranged_armor'])}", b["cost"], number(b["build_seconds"]), number(b["damage"]), number(b["range"]), number(b["cooldown"])] for b in data["buildings"]]))
    parts += ["", "大本营开局赠送，成本列为重建费用。", ""]
    for level in range(4):
        parts += [f"### 攻击科技 {LEVELS[level]}：单位拆除建筑", "", table(["攻击者 ↓ / 建筑 →", *[b["name"] for b in data["buildings"]]], [
            [u["name"], *[cell(building_lookup[u["id"], b["id"], level]) for b in data["buildings"]]] for u in units]), ""]
    parts += ["## 大本营与箭塔攻击单位", "", "建筑攻击不享受军事攻击科技，目标军事单位仍正常获得防御科技。", ""]
    defenses = {(r["attacker"], r["defender"], r["defense_level"]): r for r in data["defense_matchups"]}
    for building in (b for b in data["buildings"] if b["damage"] > 0):
        parts += [f"### {building['name']}", "", table(["目标 / 目标防御科技", *LEVELS], [
            [u["name"], *[cell(defenses[building["id"], u["id"], level]) for level in range(4)]] for u in units]), ""]
    if "impact_validation" in data:
        impact = data["impact_validation"]
        labels = {"center": "中心弓手", "inner": "内圈弓手", "edge": "边缘弓手", "outside": "范围外", "friendly": "友军", "edge_siege": "边缘攻城器", "edge_building": "边缘建筑"}
        parts += ["## 真实投石落点验证", "",
            f"以下数据来自 {impact['build_id']} 的 `tests/catapult_impact_test.gd`，专测 {impact['checks']} 项检查，失败 {len(impact['failures'])} 项。实际创建单位、建筑和弹丸，经原生物理查询与真实 `receive_hit` 结算记录。", "",
            "距离按目标占地边缘至爆心计算，范围外为大于 3；建筑沿用建筑实际占地计算。中心、内圈、边缘三个同类弓手均为同一发投石命中，不以手写距离倍率替代实测。", "",
            table(["样本", "目标", "占地边缘距爆心", "实际伤害", "预期伤害"], [
                [labels.get(s["label"], s["label"]), names.get(s["target"], s["target"]), number(s["footprint_distance"]), number(s["actual"]), number(s["expected"])] for s in impact["uniform_splash_samples"]]), "",
            f"对应原始日志 SHA-256：`{impact['source_sha256']}`。", ""]
    result = data["validation"]
    parts += ["## 数据生成与校验", "",
        f"本报告包含 {len(data['matchups'])} 项单位攻防科技组合、{len(data['building_matchups'])} 项单位攻建筑组合、{len(data['defense_matchups'])} 项建筑攻单位组合；自动完成 {result['checks']} 项检查，失败 {len(result['failures'])} 项。", "",
        "命中次数边界检查要求：前 N−1 下仍有生命，第 N 下造成致死伤害；同时检查科技不反向削弱、资源加成与实际 PlayerState 一致、农民不享军事科技，以及本版五炮镜像、投石至少四击等要求。它验证公式与数据一致性，实际全半径同伤、动画、迷雾、联机和性能另行进行集成验证。", "",
        ("本报告已附当前版本真实投石落点专测，中心、内圈与边缘同伤及友军过滤的实测记录见上一节。" if "impact_validation" in data else
         "当前状态：已完成静态资源与伤害公式审查；本报告暂未附真实投石落点专测结果，范围均匀伤害的实际验证仍待完成。"), "",
        "从仓库根目录重新导出当前数值（此命令不重新执行或附入投石落点专测）：", "", "```powershell",
        'python tools/generate_balance_report.py --godot "C:/Program Files/Godot/Godot.exe" --validate-final',
        "```", "", "如需附入新的真实落点验证，先运行 `tests/catapult_impact_test.gd` 并保留日志，再给上面的命令加 `--impact-log <日志路径>`。日志中的版本、实际伤害和当前资源必须一致。", "",
        "保留已记录的投石证据，仅从已导出的权威 JSON 重新排版：", "", "```powershell",
        f"python tools/generate_balance_report.py --from-json report/balance-{data['build_id']}.json --validate-final",
        "```", "", "机器 JSON 内 `source_sha256` 对应生成时的真实资源和计算脚本；`matchups` 保留单次伤害、有效护甲、科技加值、每秒理论伤害、致死前剩余生命等完整数据，可用于二次审查。", ""]
    return "\n".join(parts)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--godot", default=shutil.which("godot") or "C:/Program Files/Godot/Godot.exe")
    parser.add_argument("--from-json", type=Path)
    parser.add_argument("--output-dir", type=Path, default=ROOT / "report")
    parser.add_argument("--validate-final", action="store_true", help="Also enforce the approved durability patch requirements.")
    parser.add_argument("--impact-log", type=Path, help="Attach the real CATAPULT_IMPACT_RESULTS emitted by the scene integration test.")
    args = parser.parse_args()
    args.output_dir.mkdir(parents=True, exist_ok=True)
    if args.from_json:
        data = json.loads(args.from_json.read_text(encoding="utf-8"))
    else:
        work = ROOT / ".local" / "balance-report"
        work.mkdir(parents=True, exist_ok=True)
        exported = work / "godot-balance.json"
        baseline_commit, baseline_hashes, baseline_directory = prepare_baseline(work)
        command = [args.godot, "--headless", "--path", str(ROOT), "--script", "res://tools/export_balance_report.gd", "--", str(exported), baseline_directory]
        try:
            result = subprocess.run(command, cwd=ROOT, capture_output=True, text=True, encoding="utf-8", errors="replace", timeout=45)
        except subprocess.TimeoutExpired as exc:
            print(f"Godot balance export exceeded 45 seconds; child terminated: {exc}", file=sys.stderr)
            return 2
        (work / "godot-export.log").write_text(result.stdout + result.stderr, encoding="utf-8")
        if result.returncode != 0 or "SCRIPT ERROR" in result.stderr or not exported.exists():
            print(result.stdout + result.stderr, file=sys.stderr)
            return 2
        data = json.loads(exported.read_text(encoding="utf-8"))
        data["baseline"]["source_commit"] = baseline_commit
        data["baseline"]["source_sha256"] = baseline_hashes
        data["source_sha256"] = source_hashes()
    if args.impact_log:
        content = args.impact_log.read_text(encoding="utf-8-sig")
        records = [line.split("CATAPULT_IMPACT_RESULTS ", 1)[1] for line in content.splitlines() if "CATAPULT_IMPACT_RESULTS " in line]
        if len(records) != 1:
            raise ValueError("Expected exactly one CATAPULT_IMPACT_RESULTS record in --impact-log.")
        data["impact_validation"] = json.loads(records[0])
        data["impact_validation"]["source_sha256"] = hashlib.sha256(args.impact_log.read_bytes()).hexdigest()
    data["validation"] = validate(data, args.validate_final)
    if data["validation"]["failures"]:
        print(json.dumps(data["validation"], ensure_ascii=False, indent=2), file=sys.stderr)
        return 1
    stem = "balance-" + data["build_id"]
    json_path = args.output_dir / (stem + ".json")
    markdown_path = args.output_dir / (stem + ".md")
    json_path.write_text(json.dumps(data, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    markdown_path.write_text(render(data), encoding="utf-8")
    print(json.dumps({"markdown": str(markdown_path.resolve()), "json": str(json_path.resolve()), **data["validation"]}, ensure_ascii=False))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
