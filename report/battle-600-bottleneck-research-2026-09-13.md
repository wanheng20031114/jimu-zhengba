# 600 单位卡顿归因与 RVO2 源码研究

2026-09-13。本次完成分项计时、Release 隔离对照和参考源码审查。**600 单位持续战斗仍未达到可玩标准；主要压力集中在 CPU 的单位决策、目标查询与筛选、视觉动画和逐部件更新。证据不支持把卡顿主要归因于远程弹道，也不支持通过更换 RVO 库或直接删掉移动碰撞解决。**

当前游戏使用的全局寻路、局部避让、墙体碰撞和目标查询是不同的工作。`warmtrue/RVO2-Unity` 对局部避让与显示分离有参考价值，但它不是完整 RTS 寻路器；Godot 已经包含原生 C++ RVO。此次没有把第三方代码接入游戏，也没有启用改变战斗行为的诊断开关。

**测量对象与方法**

沿用上一阶段实际 600 单位战斗的冻结资源和源代码：基于 `3f6fc5c` 加当时工作区资源，原始 PCK SHA-256 为 `d9793d8e108679d40960cebd32e2cff37fee18508d9079705139fb181afef0af`。冻结副本保存在 `.local/battle-600-20260913/release-3`。诊断构建再复制该副本，验证原文件哈希后，才在新副本插入计时或对照开关。用户正在编辑的工程、单位资源和正式导出配置未被这些实验改写。

机器为 i9-10900KF、RTX 3080、64 GiB 内存；Godot `4.6.3.stable.official.7d41c59c4` 官方 Windows Release 模板，Vulkan Forward+，1600×900，关闭帧率上限与 VSync，30 TPS、正常 time scale。保留用户正常编辑器，未关闭其他应用，因此这是这台工作站的实测，不是独占机器上的硬件极限。

使用真实 4v4 场景、300 对 300、八个原生玩家各 75 单位。纯骑兵为骑士与轻骑兵；混编包含剑士、矛兵、盾卫、弓手、两类骑兵、投石车、火炮、战象、工程兵。所有单位分散出生、通过正常命令通道接敌，存在真实攻击和伤害。以 HP×100 保持整个阶段 600 单位，关闭机器人、经济生产和网络。后续新兵种不在这个冻结基线内。正常 HP 场景及“单位死后 FPS 回升不能代表 600 单位可玩”的证据，见上一份 [Release 战斗基线](battle-600-performance-2026-09-13.md)。

每次先预热，再测下令 5 秒、持续交战俯视 30 秒、近景交互 20 秒。计时均为真实墙钟；不使用 `--fixed-fps`、无头 FPS 或缩减模拟频率。每项实验依次执行，有外部超时与进程退出核验。

外部观察每 5 秒记录其他测试用 Godot 进程。初次 baseline、static-motion、frozen-batches、stationary-pruning，以及关闭避让的反例曾观察到其他任务的验证进程；这些记录完整保留，但 `eligible_for_performance_comparison=false`。下方性能表使用没有这类观察记录的样本，并标明复测。5 秒采样仍可能漏掉更短活动，因此没有将其描述为独占机器测量。

计时构建记录 22 个入口的累计耗时、调用次数和单次最大值；对照构建不插入这些方法计时包装。计时会增加开销，尤其会改变临界负载下的追赶次数，因此 **profile 构建的 FPS 不用于宣称性能下降或优化收益**。下表分项时间为每模拟步累计均值，有嵌套的入口不能相加。

**第一来源：反复搜索和筛选攻击目标**

持续交战阶段的入口计时如下。其余完整阶段、命令响应与构建哈希保存于 [机器可读证据](battle-600-bottleneck-research-2026-09-13.json)。

| 入口 | 600 骑兵，ms／模拟步 | 600 混编，ms／模拟步 | 范围 |
|---|---:|---:|---|
| `BattleUnit._physics_process` | 23.39 | 16.01 | 单位决策总入口，包含下面的搜索、追击等子项 |
| `_refresh_target` | 10.54 | 6.10 | 搜索状态判断、物理候选查询、敌我／视野／射程／优先级筛选 |
| 其中原生 `intersect_shape` | 4.03 | 2.35 | 只计目标查询调用，包含返回候选结果的成本 |
| `_chase_velocity` | 4.99 | 2.49 | 追击预测、直达判定、路径跟随等，包含相应子调用 |
| `_apply_velocity` | 4.64 | 2.67 | 在避让回调中移动角色并更新实际速度、脚步等 |
| 其中 `move_and_slide` 包装 | 3.02 | 1.53 | 移动碰撞调用，含极小包装与开关判断开销 |
| `PathBudget._physics_process` | 0.81 | 0.09 | 路径队列派发与查询；不含单位侧每次追击判断 |
| 整个 `ProjectilePool._physics_process` | 0.00 | 0.48 | 全部活动弹道与视觉更新，包含命中子调用 |

骑兵持续阶段执行了 37,572 次 `_refresh_target`，其中 30,298 次进入原生候选查询。已有 0.3–0.4 秒随机错峰，并非每个单位每步查询，但拥挤前线仍会反复查询大范围候选。一次最多返回 64 项，再逐个做脚本判断。当前目标被堵住、只想换成一个已经进入攻击范围的目标时，仍沿用原来的视野范围球形查询；许多候选随后被射程判断排除。这是源码与计时共同定位的优化入口。

因此“物理查询慢”和“战斗 AI 慢”在此处有交集。仅把 `CharacterBody3D` 换成 `Node3D`，不会消除这些目标查询及后续筛选。另一方面，`max_results=64` 是候选上限，接口没有承诺按距离排序，不能等同于保证拿到最近的 64 个敌人；不能为了速度继续盲目减小上限。[Godot intersect_shape 接口](https://docs.godotengine.org/en/4.6/classes/class_physicsdirectspacestate3d.html#class-physicsdirectspacestate3d-method-intersect-shape)。

成熟 RTS 的可借鉴做法是独立的逻辑空间索引：OpenRA `ActorMap` 维护空间分桶，`ActorsInBox` 只遍历覆盖的桶；0 A.D. `CCmpRangeManager` 使用 `FastSpatialSubdivision`，从平面位置检索候选，再处理范围和实体条件。这两个源码入口比移植另一套 RVO 更直接对应本次最大的搜索开销。[OpenRA ActorMap](https://github.com/OpenRA/OpenRA/blob/f3ec7f8e1593b482f85fd101652deb740c33dee6/OpenRA.Mods.Common/Traits/World/ActorMap.cs#L644)、[0 A.D. RangeManager](https://github.com/0ad/0ad/blob/61a3b9507d974084e6badb88a0826bd89a6d5b8b/source/simulation2/components/CCmpRangeManager.cpp#L1195)。0 A.D. 引用的是 2024 年归档的 GitHub 镜像，不代表当前 Gitea 版本。

**第二来源：已经批量绘制，但视觉工作仍占用 CPU**

`UnitRenderBatches` 已用 MultiMesh 降低绘制调用。原有可编辑模型和 AnimationPlayer 仍然存在；每个显示帧，GDScript 遍历可见模型及部件，读取 `get_global_transform_interpolated()`，逐个调用 `set_instance_transform()`。计时中纯骑兵提交约 8,664 个部件，混编约 5,252 个；该入口分别约 **9.01 和 6.09 ms／显示帧**。这里的单位是显示帧，不能与上表直接相加。

这些工作包含 CPU 动画求值、节点变换、插值读取和实例数据提交。MultiMesh 让 GPU 高效重复绘制，并没有自动把上述逻辑变成 GPU 动画。冻结视觉动画的对照中，骑兵 SceneTree 回调段从无并行测试记录的 baseline 复测值 27.58 降到 22.61 ms／模拟步，模拟吞吐恢复到约 30 TPS；但整体仍只有 4.25 FPS。差值还包含战局演进带来的连带变化，不能全当成独立的 AnimationPlayer 精确自耗时。

可研究的后续路线是：先比较原生 MultiMesh 整块 buffer 提交和可见部件更新方式，再比较保存的 Skeleton3D 资源与离线烘焙动画纹理。Godot 文档明确提供顶点着色器实例动画、浮点纹理以及 `multimesh_set_buffer()` 的入口；项目已有 `tools/build_rigid_skin.gd`，可作为对照基础。骨骼方案仍可能保留 CPU 动画求值并增加单位级绘制调用，不能预设它一定获胜。[Godot MultiMesh 优化说明](https://docs.godotengine.org/en/4.6/tutorials/performance/using_multimesh.html)。该教程标记部分内容尚未针对 4.6 更新，落地时还需核对对应类 API。

GPU 动画适合表现层；攻击出手时刻、弹道发射点和命中不能受是否入屏影响。应保留编辑器中的原始场景作为资源源头，导出时生成确定性数据；逻辑只采样必要的发射点，显示端按动画相位播放。直接降低整个模拟频率，或者把所有动画粗暴改到显示时钟，会破坏目前已经验证的出手和屏外同步规则。

**隔离对照：删掉一个系统后发生什么**

以下全部为没有方法计时包装的同一诊断 PCK，并且未观察到其他测试进程并行。只改一项开关；“不绘制”仍保留模型层级、动画和批处理脚本，“冻结批提交”仍保留原模型的动画与发射点。跳过碰撞、冻结姿态或冻结显示位置都改变了正常游戏行为，仅用于归因。

| 600 骑兵持续阶段 | FPS | 帧间隔 P95，ms | TPS | 回调段均值，ms／步 | GPU P95，ms |
|---|---:|---:|---:|---:|---:|
| 正常行为基准，复测 | 3.15 | 326.66 | 25.17 | 27.58 | 37.97 |
| 隐藏单位绘制 | 3.13 | 331.54 | 25.04 | 27.68 | 20.25 |
| 冻结视觉动画 | 4.25 | 267.11 | 30.00 | 22.61 | 37.40 |
| 跳过墙体移动检测 | 3.20 | 322.74 | 25.62 | 27.90 | 37.13 |
| 冻结批量部件提交，复测 | 3.22 | 321.20 | 25.76 | 27.71 | 31.85 |
| 静止单位不搜索避让邻居，复测 | 3.13 | 331.06 | 25.00 | 27.78 | 37.75 |

后续实现阶段复核发现：保存的主场景已经将 `stationary_avoidance_pruning_enabled` 设为 true，所以该行开关在此场景中没有改变行为。不能把它理解为开启该优化后的有效隔离对照，也不能用脚本默认值 false 推断运行状态。新的实现和按用户 10–20 FPS 要求进行的验收见 [优化报告](battle-600-optimization-2026-09-13.md)。

隐藏单位绘制显著降低 GPU 时间，却几乎没有改善 600 骑兵的整局 FPS；这支持 CPU 主导判断。GPU 并非零成本：部分正常绘制阶段的 GPU P95 超过 33 ms，不能据此承诺 CPU 问题修完就一定达到 30 FPS。保留编辑器及共享 GPU、稀疏显示帧下的 GPU 时间戳和功耗状态也会影响数值。

完全关闭避让的反例尤其重要：持续阶段记录到约 19.24 FPS，但伤害事件从正常行为复测的 2,777 次变为 16,348 次，单位重叠收缩成窄线。它把“拥挤前线大量单位持续追击但无法接敌”的状态，变成了更多单位直接进入攻击状态，移动、搜索与动画负载都随之改变。**该实验后续交互阶段出现死亡，触发保持 600 存活单位的断言失败，整次运行被列入 `rejected_runs`，未计为通过；该场还存在并行测试观察，19.24 FPS 仅保留为原始记录。** 不能用其 FPS 差值认定纯 RVO 运算占了大部分 CPU，更不能把这种重叠行为作为优化提交。[正常避让截图](battle-600-rvo-baseline.png)、[关闭避让截图](battle-600-rvo-disabled.png)。两张图拍摄于仍为 600 存活单位的持续阶段，模拟时间因 TPS 不同而不同。

`static-motion` 只启用已有的保守静态占地证书：空地直接积分，不能证明安全时仍调用原生角色移动。两次运行都完成了逻辑完整性检查，但都观察到其他测试进程，因此不进入性能比较表，也不据此修改生产默认值。其价值需要结合无干扰性能复测，以及墙角、狭口、旋转形状、建造／拆除、传送和非平地回归单独评估。直接跳过碰撞的实验更不能作为可发布优化。

各场景按墙钟采样，模拟步数、接敌状态和命令落点会随负载变化。因此对照用于判断瓶颈是否足以解释数量级差异；**表内 FPS 比值不等于可复现的单项优化百分比**。所有实验都需同时看 TPS、持续伤害和 600 人数约束。

**寻路、避让与“物理耗时”的边界**

当前全局路线由 `PathBudget` 管理，直达走廊经体积通行检查后不发起 A*；原生查询按预算派发。计时构建的持续阶段，原生路径查询总时间平均为骑兵 0.77 ms／步、混编 0.067 ms／步，P95 分别 1.56、0.37 ms。该派发入口远低于目标搜索总成本。单位侧的追击预测与走廊判定仍有成本，应继续精简重复读取和校验；当前数据不支持以更换整套全局寻路算法作为第一项性能改造。开局 600 人同时下令、频繁建筑更新、窄口完成率与路径长度还需使用各自的压力场景，不能从持续混战推导所有拓扑都已支持 600 人。

Godot 参考源码 `NavMap3D::step` 已使用 RVO2D／RVO3D 和原生 WorkerThreadPool；本次运行读到的 `avoidance_use_multiple_threads` 为 true，单位使用 XZ 平面的 2D 避让，最多 10 个邻居。`NavigationAgent3D` 的名字不意味着正在进行三维球体避让。[Godot 避让源码](https://github.com/godotengine/godot/blob/35e80b3a8822a9df9be390814b62f44c0a9c69e8/modules/navigation_3d/nav_map_3d.cpp#L594)。

特别需要修正监控数值的解释：`TIME_PHYSICS_PROCESS` 在引擎主循环中覆盖 SceneTree、导航服务器、PhysicsServer 及有关消息刷新；`TIME_NAVIGATION_PROCESS` 的范围包含 `dispatch_callbacks()`，所以本项目的 `_apply_velocity` 和 `move_and_slide()` 也记在里面。这两个监控还按约一秒窗口发布最大值；对这些缓存样本求平均，不是每步物理或纯 RVO 的平均耗时。不能把它们与脚本入口或 GPU 时长直接求和，也不能通过二者相减精确得到 Jolt 的自耗时。[主循环计时源码](https://github.com/godotengine/godot/blob/35e80b3a8822a9df9be390814b62f44c0a9c69e8/main/main.cpp#L4518)、[导航回调范围](https://github.com/godotengine/godot/blob/35e80b3a8822a9df9be390814b62f44c0a9c69e8/modules/navigation_3d/3d/godot_navigation_server_3d.cpp#L1383)。标签源码与本机官方二进制的提交后缀不同，因此这是 4.6.3 对应实现的解释，未声称对二进制做过逐函数原生采样。

正常骑兵场持续达到每个显示帧 8 次物理步的追赶上限。单位决策、动画和避让回调随这些步重复执行，显示与输入反馈只能等待；实测约 3 FPS 和 24 TPS。提高追赶上限可能进一步推迟显示，降低 TPS 则改变战斗速度，这两种方法都不能当作性能修复。

**远程与是否需要物理引擎**

现有单位为 `CharacterBody3D`，使用浮动模式、碰撞 mask 3；单位自身处于单位／阵营层，因此单位之间的分离主要由 RVO 处理，并没有全军逐对刚体接触求解。Jolt 用于静态场景移动检测、目标空间查询、点选和建造等操作。

`ProjectileFlight` 是复用的 RefCounted 数据记录。箭和炮弹按参数推进轨迹，在到达时确认目标并结算；没有每步刚体模拟或弹道扫掠。投石车的范围攻击在命中时做一次缓存的球形查询，再进行平面距离筛选。混编弹道池平均约 0.48 ms／模拟步，其中命中入口约 0.20 ms；这些是嵌套时间。纯骑兵持续阶段没有活动弹道，仍严重卡顿。因此这一负载下远程弹道不是首要来源。此测试离线，不能用于排除线上快照、编码或网络调度的额外成本。

对于目前平地 RTS，专门的二维位置、半径、障碍占地和范围查询可以替代部分通用三维物理工作。但删除物理引擎还要重建点选、放置、墙体接触、建筑边缘攻击和范围伤害等语义，风险大于只精简已证实昂贵的查询。当前证据支持逐项替换和差分验证，不支持一次性取消物理。

《星际争霸 II》也不能当作“没有物理引擎”的例子。暴雪官方 1.5.2 补丁说明明确提到物理优化，以及布娃娃死亡、冲量、水面碰撞等物理特效支持；这是历史版本的直接证据，不证明当前版本的所有单位移动或命中都由物理求解器驱动。[暴雪官方补丁说明](https://news.blizzard.com/en-gb/article/10054519/starcraft-ii-wings-of-liberty-patch-1-5-2)。

更贴合本次问题的是 Blizzard 的 Dominic Filion、Rob McNaughton 在 SIGGRAPH 2008 的渲染文章：面对高单位数量导致的 CPU 压力，团队把画质提升尽量放在 GPU，并控制批次数和顶点规模。这是可借鉴的历史设计原则，不是当前 SC2 源码或本项目性能保证。[StarCraft II: Effects and Techniques，印刷页 136–137](https://www.realtimerendering.com/advances/s2008/SIGGRAPH2008%20-%20StarCraftII.pdf)。

**用户提供的 RVO2-Unity：具体借鉴与限制**

已浅克隆到 `tmp/RVO2-Unity`，固定提交 `cbc0dfcd5dfcbe228243f1502b5c4f7a2257015a`，提交日期 2019-03-04。README 定位是 Unity 2017.1.2 的简单示例，上游为 `snape/RVO2-CS`；根目录与库源码标注 Apache-2.0。只阅读源码，未构建、执行或加入导出包。[用户指定仓库](https://github.com/warmtrue/RVO2-Unity)。

| 源码入口 | 可借鉴内容 | 应保留的边界 |
|---|---|---|
| `Simulator.doStep`、`KdTree` | 集中构建邻居索引；分阶段计算速度，再统一更新位置；按组并行 | Godot 已有原生实现，应先测回调与数据组织成本 |
| `Agent.update`、`GameAgent.Update` | 平面位置积分与 Unity 显示对象分离 | 示例没有完整战斗、全局路线、建造、迷雾及命中系统 |
| `ObstacleCollect.Awake` | 从场景障碍生成平面轮廓，集中预处理 | 示例转换忽略 BoxCollider 的 center 与旋转，且未展示动态建造／拆除维护 |
| `GameMainManager.Update` | 统一调度一个模拟器 | 设置 0.25 秒步长，却每个显示 Update 调用 doStep；不能照搬为本项目模拟时钟 |
| `GameAgent.Update` 朝向与扰动 | 展示偏好速度和微扰的用途 | 朝向读取偏好速度，并要求两个分量都超过阈值；随机微扰没有本项目的确定性约束 |

对应的固定版本源码：[Simulator](https://github.com/warmtrue/RVO2-Unity/blob/cbc0dfcd5dfcbe228243f1502b5c4f7a2257015a/Assets/Scripts/RVO/src/Simulator.cs)、[Agent](https://github.com/warmtrue/RVO2-Unity/blob/cbc0dfcd5dfcbe228243f1502b5c4f7a2257015a/Assets/Scripts/RVO/src/Agent.cs)、[GameAgent](https://github.com/warmtrue/RVO2-Unity/blob/cbc0dfcd5dfcbe228243f1502b5c4f7a2257015a/Assets/Scripts/GameAgent.cs)、[ObstacleCollect](https://github.com/warmtrue/RVO2-Unity/blob/cbc0dfcd5dfcbe228243f1502b5c4f7a2257015a/Assets/Scripts/ObstacleCollect.cs)、[GameMainManager](https://github.com/warmtrue/RVO2-Unity/blob/cbc0dfcd5dfcbe228243f1502b5c4f7a2257015a/Assets/Scripts/GameMainManager.cs)。

ORCA 原始论文区分了局部碰撞避免和全局路线规划。避障约束不负责决定从墙的哪一侧走向目标；高密度下约束也可能没有共同可行速度，算法会选尽可能安全的速度。因此不能承诺“换成 RVO2 就永不回头、永远最短路、任意拥挤都不重叠”。应继续保留前一阶段的单向路径推进、版本失效与编队分配回归。[van den Berg 等，Reciprocal n-body Collision Avoidance，2011，尤其第 1、5.3、5.4 节](https://ics-websites.science.uu.nl/docs/vakken/mcrws/papers_new/van%20den%20Berg%20et%20al%20-%202011%20-%20Reciprocal%20n-body%20collision%20avoidance.pdf)、[作者项目页](https://gamma-web.iacs.umd.edu/ORCA/)。

进一步对照发现，**同源算法的更新顺序也需要审查**。Unity 示例在所有 `computeNewVelocity` 完成后才统一 `update`；Godot 所查标签的 `compute_single_avoidance_step_2d` 对每个代理连续计算、更新，而 `Agent2D::update` 会写入邻居计算读取的位置和速度。这提示需要检查同一步输入是否一致，而不能仅凭算法名字认为两份实现等价。[Godot Agent2D 读写位置与速度](https://github.com/godotengine/godot/blob/35e80b3a8822a9df9be390814b62f44c0a9c69e8/thirdparty/rvo2/rvo2_2d/Agent2d.cpp#L269)。

为此新增了 `tests/rvo_step_order_probe.gd`，在独立最小项目中直接使用本机 NavigationServer3D，不加载游戏、路径、角色碰撞、动画或渲染。两个代理的位置为 `(-1, 0, 0)` 和 `(1, 0, 0.2)`，初速度与偏好速度为相向的 3 m/s，半径 0.6 m，30 TPS；只交换注册顺序。关闭／打开多线程设置分别执行 12 组配对，共 24 组。**按物理身份比较首步结果，最大速度差均约 0.77135 m/s**。一个顺序下 A 的结果约为 `(2.20669, 0, -1.32310)`，反序后为 `(2.60334, 0, -0.66155)`。[原始结果](rvo-step-order-2026-09-13.json)。

该实验确认本机原生避让结果对注册顺序敏感，是后续避让正确性研究的新线索；它不是线程竞态检测，也没有证明用户画面中的回头由这一点直接造成。关闭多线程并未消除这里的顺序差异。后续应对照双阶段更新／不可变输入快照，测回避质量、重叠、到达率和成本；此次未修改引擎，也未用脚本额外叠加第二套 RVO。

**按证据排序的改造方向与验收**

1. 优先拆分目标获取与近身换目标。按查询意图限制候选范围；随后对照集中式二维实体索引，复用位置、阵营和半径数据。查询半径必须包含完整目标体积，保留迷雾、HOLD、MOVE 反击、显式锁定、最小射程和建筑边缘规则。用原有查询做差分参照，覆盖超过 64 个候选的拥挤场景；不能靠降低反应频率、漏掉候选取得 FPS。
2. 压缩单位状态热路径和视觉 CPU 工作。比较一次连续数据读取与反复节点访问，减少多次走廊确认；比较原生批 buffer、骨骼资源、离线 GPU 动画数据。必须测试攻击前摇、屏外发射点、再入屏、死亡、暂停和联机副本，维持原始模型可编辑性。
3. 保留原生 RVO，围绕静止单位、邻居范围、优先级与障碍更新做独立回归；同时把拥堵接敌作为战斗调度问题处理，避免后排单位长期重复完整追击／换目标搜索。接敌位置分配、近身候选更新和可解释的等待状态需单独验证完成率及响应，不能靠取消体积限制解决。邻居索引与物体运动分离是参考库的有用思路；默认参数和随机扰动不是可直接套用的调优结果。局部回避的短暂后退与错误回追旧路点应分别统计。
4. 最后决定静态移动和空间查询保留多少 Jolt。空地证书是一个可测的渐进方案；整体移除物理须先证明它在帧预算中的必要性，并对照所有交互与碰撞语义。

每个候选都需重新运行无探针的 600 人 Release 持续战斗，报告人数、真实伤害、TPS、显示帧 P95、最大卡顿及指令响应；再测正常 HP、狭口、建筑变化和线上房主。沿用本阶段验收门槛：至少 30 FPS、P95 帧间隔不高于 50 ms、至少 29 TPS、没有超过 250 ms 的停顿。当前结果尚未满足，不能把某个子系统加速当成整体可玩。

**复现入口与交付范围**

```powershell
# base 必须是上一阶段的冻结构建；新目录不会覆盖旧证据。
python tools/build_battle_600_diagnostics.py --base .local/battle-600-20260913/release-3 --output .local/battle-600-analysis-new/profile --profile
python tools/build_battle_600_diagnostics.py --base .local/battle-600-20260913/release-3 --output .local/battle-600-analysis-new/ablation

./tools/run_battle_600_benchmark.ps1 -Executable .local/battle-600-analysis-new/ablation/bin/battle-600.exe -OutputDirectory .local/battle-600-analysis-new -RunId cavalry-baseline -Cavalry
./tools/run_battle_600_benchmark.ps1 -Executable .local/battle-600-analysis-new/ablation/bin/battle-600.exe -OutputDirectory .local/battle-600-analysis-new -RunId cavalry-no-unit-draw -Cavalry -Experiment no-unit-draw
```

其他本次执行的开关与结果见上表。`tools/summarize_battle_600_diagnostics.py` 收集明确指定的 run ID，验证 Release、600 人数、真实伤害和原始断言，保存原生计时、探针、命令响应及并行测试观察。复用已有 ID 会被拒绝；错误地对普通基准包请求诊断开关，也会在结果核对时被拒绝。

本次提交内容是隔离诊断工具与研究证据。跳过碰撞、冻结动画等代码只注入 `.local` 副本，没有变成正式游戏功能。参考仓库位于被 Git 和 Godot 导入共同排除的 `tmp`，固定版本清单也保存在 `tmp/README.md`。

共执行 14 场完整 Release 诊断：13 场共 8,456 项逻辑完整性检查通过；其中 8 场未观察到并行测试进程，包含 2 场入口计时和 6 场无探针对照。其余 5 场保留记录但不进入性能比较。另 1 场关闭避让实验在交互阶段降到 599 人，651 项检查中 1 项失败，明确列为拒收数据。另完成原生 RVO 的 24 组配对观察，以及工具 Python 语法和差异空白检查。这些通过项不是 FPS 验收通过。

已通过进程命令核实：本任务启动的所有基准、构建与无头探针均退出，正常用户 Godot 编辑器保留运行。
