# 发布包完整对局验收

`--match-smoke` 经过正式 Session 入口，加载默认 1v1 地图，将两个槽位设为标准 Bot。双方使用正常的 320 金币、3 名农民、大本营与采矿收入，付费建造、招募、交战，直到正式胜负逻辑结束对局。自检不会生成额外军队、发放补贴、修改伤害或强制胜利。

验收场景保存在 `scripts/qa/release_match_probe.tscn`，由 Session 显式引用，因此随 `all_resources` 发布配置导出；不依赖被排除的 `tests/`。普通启动不会创建这个节点，已有 `--network-smoke` 分支保持优先。

实际发布 EXE 的无头快速验收：

```powershell
python tools/run_release_match_smoke.py builds/windows/AshenCrown.exe --fast --headless --output artifacts/release-match
```

需要观察正式渲染时去掉 `--headless`；去掉 `--fast` 则以正常速度观看。也可直接运行 `AshenCrown.exe -- --match-smoke`。默认只验证 1v1，不应组合 `--2v2`、`--capture` 或其他启动自检标记。

源码使用同一入口：

```powershell
python tools/run_release_match_smoke.py 'C:/Program Files/Godot/Godot_console.exe' --project . --fast --headless --output artifacts/source-match
```

快速模式同时将 `Engine.time_scale` 设为 10、物理频率设为 300 TPS，仍保持每次模拟更新为 1/30 秒，并逐步检查实际差值。它缩短验收等待时间，不是性能基准；不要与性能采样同时运行。[Godot Engine 官方文档](https://docs.godotengine.org/en/stable/classes/class_engine.html#class-engine-property-time-scale)

成功需要自然胜利、唯一存活队伍的军事建筑、真实伤害与阵亡、双方采矿收入、付费基础军队和已完工兵营。最多模拟 20 分钟，超时判失败。结束时先执行正式 `prepare_shutdown()`，释放对局，再打印唯一的 `MATCH_SMOKE_RESULT` JSON 并返回退出码 0。

外部 runner 保存 stdout、stderr 和 JSON，要求退出码 0、stderr 为空、完整结果满足契约；实际 EXE 还要求无 `editor` 特性。它记录子进程 PID，并在超时或中断时仅终止自己启动的进程。源码通过不能代替发布 EXE 通过，应保留两组日志。此项验收也不代替多人中继、断线重连、显示布局或性能测试。

源码验收记录（2026-09-09）：Godot 4.6.3，原生无头、10 倍速，13/13 通过；模拟 657.07 秒自然胜利，剩余建筑为 4 / 0。观察到 457 次伤害变化、74 名军事单位阵亡，双方采矿分别为 4593 / 2778 金币；逐步 delta 检查通过。runner 与 Godot 均退出码 0，stderr 为 0 字节，PID 31016 已命令核实退出。原始结果及日志在 `artifacts/source-match.json`、`artifacts/source-match.stdout.log`、`artifacts/source-match.stderr.log`。此记录仅证明源码验收；发布 EXE 需导出后单独执行上述命令。

首次发布 EXE 验收失败：模拟 1200.03 秒仍无军事单位、采矿收入或伤害，双方仅各完成一座兵营；`source_editor_feature=false`，13 项中 6 项失败，进程正常返回退出码 1。保存为 `artifacts/release-match-initial-failure.*`，不能据此宣布发布可用。随后 120 秒诊断确认原生导航网格已同步，另发现初始空路径未重试，以及导出后的建筑 `produces` 列表为空。诊断记录为 `release-match-diagnostic.*` 与 `release-match-catalogue.*`。修复路径重试、显式 PackedStringArray 默认构造，并通过 Godot 原生 ResourceSaver 重新保存受影响建筑以更新导出缓存后，执行了下述完整发布复验。

修复后实际发布 EXE 验收（2026-09-09）：`source_editor_feature=false`，13/13 通过；模拟 **593.07 秒（9 分 53 秒）**自然胜利，剩余军事建筑为 4 / 0，没有强制胜利。45 秒首次观察到伤害，累计 467 次采样伤害变化、84 名军事单位阵亡；双方真实采矿收入为 4713 / 3330 金币，均完成兵营、军工厂和学院，并生产剑士、弓箭手、骑士。大本营、兵营、军工厂的缓存资源与独立加载资源生产列表均完整一致。逐步 1/30 秒 delta 验证通过。实际运行约 60.48 秒，runner 与 EXE 均退出码 0，stderr 为 0 字节；PID 30888 与本次 runner 已命令核实退出。最终原始记录为 `artifacts/release-match.json`、`artifacts/release-match.stdout.log`、`artifacts/release-match.stderr.log`；早期失败记录仍保留用于追溯。

网络优化后的实际 0.6.0 EXE 再验收（2026-09-09，`artifacts/release-match-final.*`）：**13/13** 通过，`source_editor_feature=false`。双方按正常经济自然交战，模拟 **688.53 秒（11 分 29 秒）**后队伍 1 胜利，剩余军事建筑为 0 / 4；41 秒首次采样到伤害，累计 550 次采样伤害变化、101 名军事单位阵亡。双方采矿收入分别为 3537 / 4977 金币，均完成兵营、军工厂和学院，实际生产记录包含剑士、弓箭手、骑士以及队伍 1 的一门加农炮。未改金币、伤害或胜负，逐步 `1/30` 秒 delta 验证通过。实际墙钟约 70.02 秒，runner 与 EXE 均退出码 0，stderr 为 0 字节；PID 9240 及 runner 已通过命令确认退出。原有首次失败和先前通过日志均保留。

该轮执行期间发现的闲置农民快捷选择归属问题由独立输入回归修复，因此上述记录明确对应快捷选择修复前的导出包；该修复不影响自检中的 Bot 对局流程。

**最终交付包确认**（2026-09-09，快捷选择修复后重导，ZIP 50,868,798 B）：实际 EXE 再次 **13/13** 通过，`source_editor_feature=false`，模拟 **561.60 秒（9 分 22 秒）**自然结束，队伍 0 胜利，剩余军事建筑为 4 / 0。45 秒首次采样到伤害，426 次采样伤害变化、76 名军事单位阵亡；双方采矿收入为 4377 / 2685 金币，均完成兵营、军工厂和学院，实际军队包含剑士、弓箭手、骑士以及胜方的一门加农炮。正常经济与胜负规则未被修改，每步 `1/30` 秒检查通过。runner 墙钟 57.344 秒，EXE 与 runner 均退出码 0、stderr 为 0 字节；PID 4420 和本次辅助进程已通过命令核实退出。完整原始记录为 `artifacts/release-match-delivery.json`、`artifacts/release-match-delivery.stdout.log`、`artifacts/release-match-delivery.stderr.log`，未覆盖前面任何样本。该 EXE 的 SHA-256 为 `27a1e9e7abf42b7c828937182fd8df9337ba9ae3cc018075116a4fa11becb5af`。

6–10 分钟是普通 1v1 的调优目标，并非每一种调度与战场演化都必然满足的验收上限。前述 11 分 29 秒记录仍保留；这些有限样本验证完整对局能够自然结束，不代表所有对局时长或胜率分布。

仅用于定位的 `--diagnose`（内部 `--match-smoke-diagnose`）将运行限制为 120 模拟秒，并始终返回验收失败。它输出开局与 30 / 60 秒的金币、农民状态、矿位、生产队列、建筑原始生产列表、导航迭代/多边形/路径预算；开局还比较缓存资源与 `ResourceLoader.CACHE_MODE_IGNORE` 独立加载值。此选项不用于正式发布通过记录。
