# 600 单位持续战斗优化与验收

2026-09-13。已完成目标查询、动画求值和拥堵追击优化。在本机三组两分钟、全程 600 单位的 Release 长测中，持续平均达到 **27.6–29.4 FPS**，保留 30 TPS 和正常游戏时间；达到最新要求的 **最低 10 FPS，争取 20 FPS**。集火开局仍有短时掉帧，拥堵策略也改变了接敌节奏，见下文。

| 场景 | 持续时长，秒 | 持续 FPS | 近景 FPS | 持续帧 P95，ms | 持续 TPS | 最低完整一秒 FPS | 最少存活 |
|---|---:|---:|---:|---:|---:|---:|---:|
| 修改前骑兵 | 30 | 3.0 | 2.9 | 363.0 | 23.61 | 未采样 | 600 |
| 修改前混编 | 30 | 6.1 | 7.0 | 198.8 | 30.12 | 未采样 | 600 |
| 最终骑兵长测 | 120 | 27.6 | 27.4 | 50.2 | 30.05 | 15.9 | 600 |
| 最终混编同长度对照 | 30 | 27.9 | 28.4 | 52.7 | 30.21 | 15.0 | 600 |
| 最终混编长测 | 120 | 29.4 | 28.8 | 43.8 | 30.05 | 15.5 | 600 |
| 最终含牧师长测 | 120 | 28.8 | 27.3 | 45.3 | 30.05 | 15.5 | 600 |
| 最终骑兵点名集火 | 30 | 27.2 | 28.1 | 52.6 | 30.17 | 17.6 | 600 |

基线／最终同长度对照都是 30 秒、HP×100；长测是 120 秒、HP×400，表内明确分开。最终五场恒定 600 人测试的持续与近景阶段均达到最低验收条件，不代表所有时刻均稳定 20 FPS。集火开局五秒仍有突发：平均 13.9 FPS，最低完整一秒为 7.5 FPS，P95 131.8 ms，因此没有将开局的帧稳定性宣称为通过最低 P95 门槛。

近景相机动作到画面变化的 P95 为 44–57 ms，测的是程序注入动作后的反馈，不含操作系统输入及显示器延迟。[骑兵长测截图](battle-600-optimized-cavalry.png)、[混编长测截图](battle-600-optimized-mixed.png)。

**测量条件**

机器为 i9-10900KF、RTX 3080、64 GiB；Godot 4.6.3 官方 Windows Release、Vulkan Forward+、1600×900。原有 MSAA、TAA、阴影和 1.0 渲染比例保持一致；取消帧率上限和 VSync。基线重新冻结自 `145faf9` 及当时工作区资源，包含当前牧师系统；没有把更早报告的冻结版本当成这次修改前的基线。

两个版本的资源、地图、项目配置和 Release 模板哈希相同。差异是六个游戏脚本、基准脚本，以及主场景文件的换行符；主场景没有语义变化。完整源文件清单、PCK 哈希、原始结果、环境观察和测试结果见 [机器可读证据](battle-600-optimization-2026-09-13.json)。

使用实际 4v4 场景，八个玩家各 75 单位，通过原生命令通道交战。标准混编有剑士、矛兵、盾卫、弓手、骑士、轻骑兵、投石车、火炮、战象和工程兵；牧师变体把每个玩家的两名弓手换成牧师，合计 16 牧师。集火变体让每个玩家的 75 人明确攻击一个最近的敌人，检验显式目标锁定。

30 秒对照使用 100 倍生命值，120 秒长测使用 400 倍，维持完整的 600 个单位；攻击间隔、伤害数值、碰撞和避让仍实际运行。每场另有 5 秒开局同时下令和 20 秒近景交互。正常生命值测试单独验证死亡、目标切换及后排推进，其 FPS 不用于证明持续 600 人达标。

机器人、经济生产和网络在此性能夹具中关闭。用户的正常编辑器及另一个正常运行的游戏保留；外部每五秒记录其 CPU 时间及其他验证进程，没有将工作站描述为独占环境。未使用无头 FPS、`--fixed-fps` 或降低模拟频率作为性能证据。功能回归中的固定显示帧率仅用于加速测试。

最低验收同时检查平均 FPS ≥10、帧间隔 P95 ≤100 ms、TPS ≥29、无超过 250 ms 的停顿；更高目标为平均 FPS ≥20、P95 ≤50 ms。完整一秒采样窗口另行记录；它既不是逐帧下限，也不能用 Godot 缓存的 FPS 监控代替。开局突发单独列出，不混入“持续阶段通过”。

**落地的结构变化**

1. **按决策需要缩小目标查询。** 已有追击目标时，换目标只搜索武器接触范围；首次发现仍覆盖完整视野。继续使用 Godot 原生空间索引，平面盒形 broad phase 后做精确射程、最小射程、建筑边缘、迷雾及优先级检查。先排除距离上不可能获选的候选，再查询可见性。取消固定 64 个结果的截断，以上下文中战斗实体总数安全约束返回上限，避免密集队伍中漏掉最近敌人。相同优先距离按实体 ID 决定，保留显式目标和前摇锁定。[Godot intersect_shape](https://docs.godotengine.org/en/4.6/classes/class_physicsdirectspacestate3d.html#class-physicsdirectspacestate3d-method-intersect-shape)、[BoxShape3D](https://docs.godotengine.org/en/4.6/classes/class_boxshape3d.html)、[SceneTree 原生组计数](https://docs.godotengine.org/en/4.6/classes/class_scenetree.html#class-scenetree-method-get-node-count-in-group)。

2. **大军团按显示需要求动画姿态。** 达到 192 个批量模型时，权威端按原有模拟时钟，在显示帧采样可见模型的原生 AnimationPlayer；位置和朝向继续使用原生物理插值。每单位合成一次插值后的父变换，减少每个肢体在物理步中的插值维护。攻击真正释放时仍精确采样发射点；屏外、暂停、死亡和重新入屏共享同一时间规则。跌回阈值以下恢复原来的部件插值；联机副本继续由快照时钟驱动。保留 `.tscn` 模型可编辑性。GPU 仍负责 MultiMesh 绘制，这次没有声称把全部动画搬到 GPU。[AnimationMixer](https://docs.godotengine.org/en/4.6/classes/class_animationmixer.html)、[Godot 物理插值进阶](https://docs.godotengine.org/en/4.6/tutorials/physics/interpolation/advanced_physics_interpolation.html)。

3. **持续拥堵时短暂等待。** 观察原生 RVO 给出的速度在期望前进方向上的投影。连续 0.6 秒低于期望前进量的 20%，才让追击等待 0.18–0.279 秒，再错峰尝试。普通 MOVE 不进入战斗等待；短暂侧向避让不触发。等待者仍作为原生避让邻居存在，每步仍检查目标有效性、攻击范围和战斗计时。敌人进入出手范围立即攻击；新的移动、停止或点名攻击立即清掉等待，显式目标不被自动替换。恢复有效前进后解除拥堵状态。这个规则也覆盖整队集火，避免只优化攻击前进。

4. **减少追击热路径的重复工作。** 单位持有类型明确的路径记录和避让 RID；调度队列仍保留 ID／世代检查。一次读取位置和朝向，复用距离、方向及路径完成状态。直达通行可以复用一个经体积收缩的无障碍矩形证明，端点仍须在区域内；地图对象、拓扑版本或半径改变即失效。只缓存可证明畅通的几何范围，不缓存旧追击目标或“堵住了”的答案。该缓存单独测试的性能差异处于波动范围，没有把它计成独立的大幅收益。

5. **普通部队不执行支援者轮询。** 支援能力在配置时确定；只有工程兵、牧师等实际提供者推进发现计时及选取工作。受治疗者的排他认领与期限继续使用对局时钟，治疗数值和间隔不受此门控影响。

前期对 [OpenRA ActorMap](https://github.com/OpenRA/OpenRA/blob/f3ec7f8e1593b482f85fd101652deb740c33dee6/OpenRA.Mods.Common/Traits/World/ActorMap.cs#L644)、[RVO2-Unity](https://github.com/warmtrue/RVO2-Unity/tree/cbc0dfcd5dfcbe228243f1502b5c4f7a2257015a) 的阅读，支持按查询意图检索候选、分离运动与显示的方向。这次实现使用项目代码和 Godot 原生能力，没有移植另一套 RVO，也没有复制 GPL 源码。源码研究的证据和边界见 [前期报告](battle-600-bottleneck-research-2026-09-13.md)。

**收益来自哪里，哪些方案没有采用**

| 阶段，均为 30 秒骑兵持续战斗 | FPS | P95，ms | TPS |
|---|---:|---:|---:|
| 本次新基线 | 2.95 | 363.02 | 23.61 |
| 查询范围与筛选 | 4.98 | 235.97 | 30.13 |
| 加按显示需要求姿态 | 9.25 | 134.14 | 30.18 |
| 姿态方案复测 | 8.55 | 140.95 | 30.17 |
| 类型化路径与状态读取 | 10.07 | 117.16 | 30.21 |
| 加几何证明缓存 | 9.78 | 129.04 | 30.19 |
| 仅速度长度识别堵塞，未采用 | 9.20 | 133.57 | 30.18 |
| 改用前进方向投影 | 24.77 | 56.65 | 30.20 |

分阶段构建说明主要收益来自目标查询、动画与拥堵调度。FPS 会随战局、原生避让和墙钟下令时刻变化，不能将相邻行相减，称为某函数的精确自耗时。带 22 个入口计时包装的构建只做归因，不纳入 FPS 验收。

没有启用已有的空地直接积分开关：在这次干净复测中约 76% 移动走了快速分支，但总体 FPS 没有改善，生产场景仍使用原生 CharacterBody 移动碰撞。对应安全差分已保留，方便以后有证据时再评估。单线程避让实验同样没有达到最低要求，未采用；该诊断构建与普通构建之间还有包装调用差异，不能把其 FPS 比值全归因于线程模式。

最初仅用安全速度的长度识别拥堵，只让少量单位进入等待，仍约 9 FPS；RVO 可以不断给出侧移／后退速度而几乎没有前进，因此改为检查方向投影。后来发现“显式攻击永远不等待”使整队集火近景退回约 9.6 FPS，最终改成每条新命令立即执行、长期堵塞再等待，并增加了对应回归。

**行为变化与限制**

拥堵等待是明确的接敌策略变化。武器数值、冷却和命中逻辑保持原样，但后排挤向前线的方式改变，不能承诺总伤害事件数量完全相同。特别是大量单位点名攻击少量前线目标时，短测从 1,476 次伤害事件降到 621 次；近景从 1,286 降到 455 次。两次都保持 600 单位和约 30 TPS。该差异包含战局演进，不是对单兵 DPS 的修改；也不能只凭帧率提升忽略这种变化。

接敌回归检查实际 24 对 24 交战、前排出手、真实伤害、HOLD 防线和通道恢复；专门的等待状态测试在 30／60 TPS 下检查开口后 0.4 秒内恢复、短侧移、立即响应新命令、目标锁定及敌人进入射程立即攻击。这些证据支持基本响应与接敌，没有证明所有密度、地形和集火安排的平衡完全等价。正常生命值战斗另见下表。

| 正常生命值阶段 | 起／止单位 | 真实伤害事件 | FPS（不作 600 人验收） | TPS |
|---|---:|---:|---:|---:|
| opening_orders | 600 → 584 | 290 | 21.2 | 29.93 |
| sustained_overview | 584 → 239 | 3544 | 36.8 | 30.19 |
| interactive_close | 239 → 119 | 1021 | 120.7 | 30.25 |


此前的路径推进和编队回归继续通过：219 条已确认身体可直达的长路线没有绕路，步兵、骑兵和混编的到达检查通过，测试内没有路径方向反转。这不等同于承诺 RVO 任何局部避让都不后退；原生避让对注册顺序敏感的线索仍成立，本次没有修改引擎更新顺序。

600 单位线上房主、机器人决策、生产工人，以及全部地图上的狭口／连续建造，不在本次持续 FPS 验收范围。网络状态和牧师同步做了功能回归，不能替代线上 600 人性能测量。

**验证和可复现入口**

16 项相关回归合计 **12,553 项断言通过**。最终五场恒定 600 人基准共 3,256 项完整性检查通过，另有正常生命值场景 649 项；这些完整性检查与 FPS 门槛分别记录。

| 回归 | 结果 |
|---|---|
| target_acquisition_test | TARGET_ACQUISITION 426 checks; 0 failures |
| batch_animation_clock_test | BATCH_ANIMATION_CLOCK 436 checks; 0 failures |
| path_budget_test | PATH_BUDGET_RESULT 94 checks; 0 failures; max_wait_ticks=12 |
| path_budget_startup_test | PATH_BUDGET_STARTUP_RESULT 15 checks / 0 failures |
| movement_navigation_test | 1023 checks; 0 failures; 219 条直达路线；三种编队均 16/16 到达；0 路径方向反转 |
| engagement_approach_test | ENGAGEMENT_APPROACH 340 checks; 0 failures |
| pursuit_attack_test | 536 checks; 0 failures; 30 / 60 TPS |
| crowd_contact_combat_test | CROWD_CONTACT_COMBAT 152 checks; 0 failures |
| priest_support_test | PRIEST_SUPPORT 47 checks; 0 failures |
| engineer_support_test | ENGINEER_SUPPORT 29 checks; 0 failures |
| congestion_wait_test | CONGESTION_WAIT 22 checks; 0 failures |
| network_game_replication_test | NETWORK_GAME_RESULTS {"failures":[],"passed":127,"total":127} |
| priest_network_test | PRIEST_NETWORK 17 checks; 0 failures |
| physics_interpolation_visual_test | PHYSICS_INTERPOLATION_RESULT 134 checks; 0 failures; 30 TPS |
| corridor_clearance_test | CORRIDOR_CLEARANCE 7209 checks; 0 failures |
| static_motion_safety_test | STATIC_MOTION_SAFETY 1946 checks; 0 failures; 1505 certified, 415 native; max error 0.00000000 |


视觉回归夹具补上等待对局初始化、停止机器人和清理其待执行命令；重复下令的弓手测试在删除夹具前让最后一条命令进入物理步。修正后实际渲染插值测试无脚本错误。没有为旧夹具缺接口而向生产代码增加探测或兼容分支。

扩展检查中的 `network_multiplayer_test` 有 312 项断言通过，但中继结束时打印三次原生 `godot_mbedtls_mutex_free` 空 mutex 错误；不把它列为干净通过，也没有以该测试宣称联机性能达标。其调用栈在未修改的中继关闭路径。旧 `unit_motion_timing_test` 使用已缺少当前 Game 接口的 `worker_ai_host`，被排除；移动时序由当前的追击、导航、拥堵及渲染测试覆盖。

```powershell
python tools/build_battle_600_benchmark.py --output .local/battle-600-review

./tools/run_battle_600_benchmark.ps1 -Executable .local/battle-600-review/bin/battle-600.exe -OutputDirectory .local/battle-600-review/runs -RunId cavalry -Cavalry -SustainedSeconds 120
./tools/run_battle_600_benchmark.ps1 -Executable .local/battle-600-review/bin/battle-600.exe -OutputDirectory .local/battle-600-review/runs -RunId mixed -SustainedSeconds 120
./tools/run_battle_600_benchmark.ps1 -Executable .local/battle-600-review/bin/battle-600.exe -OutputDirectory .local/battle-600-review/runs -RunId priests -Priests -SustainedSeconds 120
./tools/run_battle_600_benchmark.ps1 -Executable .local/battle-600-review/bin/battle-600.exe -OutputDirectory .local/battle-600-review/runs -RunId focus -Cavalry -FocusFire
./tools/run_battle_600_benchmark.ps1 -Executable .local/battle-600-review/bin/battle-600.exe -OutputDirectory .local/battle-600-review/runs -RunId natural -Priests -NaturalHealth
```

每次使用新的输出目录／run ID；依次运行，外部超时 210 秒，内部超时 180 秒。脚本核对实际时长和变体参数，验证人数、伤害及正常渲染，记录辅助进程并核验自己启动的进程退出。FPS 验收字段与夹具完整性断言分开：没有错误退出，不能自动等于性能达标。第一次 120 秒混编只给了 100 倍生命值，后段降至 596 人并触发断言，保留为拒收记录。

**对前期报告的一处修正：** 主场景原本就将 `stationary_avoidance_pruning_enabled`、`PathBudget.omit_path_metadata` 和 `cache_map_iterations` 设为 true。不能根据脚本默认值 false 认定运行时关闭；前期 `stationary-pruning` 对照在该场景中实际没有改变此开关。这次没有把它当成新启用的优化或新的收益。

交付前已通过进程命令核实：本次基准、构建及无头测试辅助进程均已退出，用户正常编辑器和正常游戏保留。当前检查记录保存于机器可读证据的 `process_cleanup`。
