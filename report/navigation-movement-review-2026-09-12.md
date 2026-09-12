# RTS 群体移动与寻路审查

这次回头和绕路来自共用移动流程的多个环节：导航多边形通道不等于几何最短路线；单位用到达圆追逐每个路点，受到避让后可能错过路点；编队又按照实体列表顺序分配终点，要求成员相互换位。骑兵的较高速度会放大这些现象，但问题不属于某一种兵种。修复覆盖所有使用 `BattleUnit` 的单位。

本次采用 Godot 原生导航查询、原生 RVO 避让和原生角色碰撞，重新明确路径查询、路径推进、编队分配的职责。参考材料包括 OpenRA、0 A.D.、Recoil、Godot 的实际源码，以及 JPS、HPA*、Polyanya、ORCA 和分块流场的原始论文或作者文章。参考仓库保存在项目 `tmp/`，没有作为运行依赖引入。

**实际运行链路与证据**

修改前的生产配置是 `shared_paths_enabled = false`。`SharedFlowField` 和 `SharedPathService` 是已有实验实现，因此不能把当前默认行军的错误归因于流场。默认链路是 `move_formation → BattleUnit → PathBudget → NavigationAgent3D → RVO → CharacterBody3D`。

`ConstructionNavigation` 把一米通行格合并成最长 12 米的矩形，并为共享边增加分割点。Godot 的搜索以多边形连接及入口为状态，再用 funnel 处理选出的通道；源码的 `_query_task_search_polygon_connections` 将旧入口投影到下一条连接边并计算代价。这个过程并不保证任意多边形划分上的欧氏全局最短路线。Polyanya 论文也明确区分了通道搜索的近似最短路线与连续空间最短路线。这里的因果判断由源码和实测共同支持，并不意味着所有 Godot 导航网格都会产生同样的绕路。[Godot 查询源码](https://github.com/godotengine/godot/blob/35e80b3a8822a9df9be390814b62f44c0a9c69e8/modules/navigation_3d/3d/nav_mesh_queries_3d.cpp#L279)、[Polyanya 论文](https://www.ijcai.org/proceedings/2017/0070.pdf)。

在实际 1v1 地图上，用固定种子抽取 1,600 对点，筛出 219 条具有骑士全身通行余量、距离大于 5 米的直线。其中 121 条原生结果超过直线长度的 1.01 倍。最差样本从 `(25.5, -6.5)` 到 `(9.5, -21.5)`，路径先向 `(29, -7)` 走，随后折返到 `(19, -7)`，总长约为直线的 1.571 倍。这个例子没有动态单位参与，排除了把全部绕路解释为 RVO 避让的可能。

回追还有独立原因：原来 `_path_velocity()` 始终返回满速，导航路点的到达距离固定为 0.4 米。Godot 的路点判断检查当前位置是否进入到达圆；它没有自动把“已经从侧面越过该点”当成完成。高速跨越、横向避让和多余的边界点会共同造成回追。等待新路径时，项目还直接朝最终目的地转身，即使真正应该走的路线仍沿着障碍另一侧。这与 Godot 官方列出的回追、频繁重算和瞬时向后看的机制相符。[Godot 路径跟随说明](https://docs.godotengine.org/en/4.6/tutorials/navigation/navigation_using_navigationagents.html#pathfollowing-common-problems)、[原生到达圆判断](https://github.com/godotengine/godot/blob/35e80b3a8822a9df9be390814b62f44c0a9c69e8/scene/3d/navigation/navigation_agent_3d.cpp#L915)。

编队终点原来直接使用选择列表的下标。下标与空间左右、前后无关，因此同一批单位改变列表顺序后可能被分到另一侧，穿过同伴、超越后再回到自己的终点。新测试将同一批成员反转列表再下令，验证每个实体仍取得相同站位。

**成熟实现的对照**

| 来源与固定版本 | 实际查看的代码 | 对本项目有用的设计 |
|---|---|---|
| OpenRA，`f3ec7f8e1593b482f85fd101652deb740c33dee6`，2026-09-05 | `HierarchicalPathFinder.cs`、`PathSearch.cs`、`Activities/Move/Move.cs` | 分层搜索与局部搜索配合；源码明确讨论粗略路径吸引单位绕向“主干道”的问题；阻挡处理区分永久障碍、暂时拥堵和等待 |
| 0 A.D.，`61a3b9507d974084e6badb88a0826bd89a6d5b8b`，2024-08-17 | `LongPathfinder.cpp`、`VertexPathfinder.cpp`、`CCmpUnitMotion.h` | 长程搜索和精细局部运动分开；用通行检查删除多余路点；接收新路径时检查能否直接到第二个路点 |
| Recoil，`05c054cbe2249feda3637cabfe122b75241113e9`，2026-09-11 | `QTPFS/PathManager.cpp`、`PathSearch.cpp`、`GroundMoveType.cpp` | 四叉树路径系统与单位运动分开；路径共享仍保留每个单位的进度；接收路径时处理已经越过起始路点的情况 |
| Godot，`4.6.3-stable` 标签，`35e80b3a8822a9df9be390814b62f44c0a9c69e8` | `nav_mesh_queries_3d.cpp`、`navigation_agent_3d.cpp` | 明确查询和跟随的真实行为；使用可复用的 `NavigationPathQueryParameters3D` / `NavigationPathQueryResult3D` |

OpenRA 对粗略路线的处理尤其贴近这次现象：`AbstractNodeForCost` 尝试推迟单位汇入抽象路径，直到那里确实需要转弯。这说明分层之后仍然必须检查直达和局部路线质量，不能把“用了分层寻路”当成不会绕路的保证。[OpenRA 实现](https://github.com/OpenRA/OpenRA/blob/f3ec7f8e1593b482f85fd101652deb740c33dee6/OpenRA.Mods.Common/Pathfinder/HierarchicalPathFinder.cs#L1222)。

0 A.D. 对新路径开头的小折线和冗余路点有专门处理；Recoil 的 `NextWayPoint` 则在首次消费路径时寻找适合当前实际位置的进度。这里借鉴的是“路点服务于前进，不要求单位机械回到历史点”的职责划分。[0 A.D. 路点处理](https://github.com/0ad/0ad/blob/61a3b9507d974084e6badb88a0826bd89a6d5b8b/source/simulation2/components/CCmpUnitMotion.h#L968)、[0 A.D. 路径平滑](https://github.com/0ad/0ad/blob/61a3b9507d974084e6badb88a0826bd89a6d5b8b/source/simulation2/helpers/LongPathfinder.cpp#L942)、[Recoil 路点推进](https://github.com/beyond-all-reason/RecoilEngine/blob/05c054cbe2249feda3637cabfe122b75241113e9/rts/Sim/Path/QTPFS/PathManager.cpp#L1728)。

0 A.D. 的 GitHub 镜像已经归档，官方说明于 2024 年迁移至 Gitea。本次官方 Gitea 的 Git 端点未返回有效仓库协议，故这里仅引用明确标注日期的历史版本，不把它称作当前版本。Godot 参考仓库的标签提交与本机二进制报告的 `7d41c59c4` 也不同；源码用于同版本系列的机制核对，具体运行结论以本机实测为准。[0 A.D. 官方仓库说明](https://github.com/0ad)。

OpenRA 为 GPLv3，0 A.D. 的主要引擎代码与 Recoil 为 GPLv2 或更新版本，Godot 为 MIT，具体仍以每个文件及随附许可为准。本次没有复制第三方实现进入游戏脚本，保留参考仓库的许可证和提交记录；`tmp/.gdignore` 阻止 Godot 导入这些参考项目，`tmp/` 也不进入本项目 Git 提交。

**算法资料与采用条件**

| 方法 | 能解决的问题 | 对这个项目的判断 |
|---|---|---|
| 原生 A* + funnel + 通行检查 | 复用既有导航网格，以明确的静态通行检查消除直达绕路 | 本次采用；无需增加运行库或重建全部地图 |
| JPS | 剪枝均匀代价网格的对称搜索，保持该网格上的最优性 | 一米格地图适合继续比较，但网格最优不等于任意角度最短路线；必须处理体型余量与动态更新 |
| HPA* | 用分区入口和缓存缩小长距离搜索空间 | 大地图、目的地分散时值得采用；要测入口选取带来的绕路和建筑更新代价 |
| Polyanya | 在凸多边形导航网格上求连续空间最短路径 | 若绕障碍后的通道选择仍不可接受，是有理论依据的候选；不能把论文基准速度直接当成本项目 GDScript 的速度 |
| 分块流场 | 让大量同目标单位共享积分场与方向场 | 适合同一目标的远程行军；需要分块、门户、通行类别、版本失效和末端独立站位，不能每个命令重算全图就假定会更快 |
| ORCA / RVO2 | 根据邻居速度选择局部避碰速度 | 保留 Godot 原生实现；局部避让不负责静态全局最短路径、编队分配或死锁的全部恢复 |

JPS 的保证针对均匀代价网格；HPA* 的原论文给出特定基准上的速度与近似质量，不能照搬为本项目收益；Polyanya 才直接针对导航网格上的几何最短路径。三者应根据地图、成本模型和可接受的路径误差选用。[JPS 原论文](https://ojs.aaai.org/index.php/AAAI/article/view/7994)、[HPA* 原论文](https://webdocs.cs.ualberta.ca/~mmueller/ps/2004/hpastar.pdf)、[Polyanya 原论文](https://www.ijcai.org/proceedings/2017/70)。

Elijah Emerson 对《Supreme Commander 2》的介绍是作者公开的技术文章，讨论分块、缓存、成本场、积分场、方向场以及不同移动类型；它不是该商业游戏的完整源码。本项目已有的整图 Dijkstra 原型与这套分块方案不能等同。ORCA 原始资料则为局部避碰提供了理论和实现背景。[流场分块原文](https://www.gameaipro.com/GameAIPro/GameAIPro_Chapter23_Crowd_Pathfinding_and_Steering_Using_Flow_Field_Tiles.pdf)、[ORCA 作者资料](https://gamma-web.iacs.umd.edu/ORCA/)。

**此次落地的结构**

```mermaid
flowchart LR
    A[移动命令与空间站位] --> B[PathBudget 请求预算]
    B --> C{全身直线通行}
    C -->|成立| D[直线路径]
    C -->|不成立| E[NavigationServer3D 原生查询]
    D --> F[PathCorridor 单向推进与可通行捷径]
    E --> F
    F --> G[本步位移限幅]
    G --> H[原生 RVO]
    H --> I[原生角色碰撞与实际位移]
    J[建筑与导航版本变化] --> B
```

`PathBudget` 直接使用原生查询对象并复用参数和结果容器。它成为路径查询与完成状态的唯一所有者，`NavigationAgent3D` 继续提供避让。单位逻辑和诊断读取 `current_path()` / `at_path_end()`，不再让代理的懒查询 getter 隐式决定是否重算或完成命令。这是 Godot 官方支持的低层查询用法。[查询对象文档](https://docs.godotengine.org/en/4.6/tutorials/navigation/navigation_using_navigationpathqueryobjects.html)。

普通移动在任何距离都先使用现有通行格缓存检查全身扫掠走廊。检查成功就保留起终点组成的直线路径；这是有障碍数据依据的捷径，不是只检测终点或穿过碰撞体。缓存只为本项目的导航层 1 提供这种证明，其他导航层继续按原生查询路径运动。

新增的 `PathCorridor` 是纯数据对象，不增加场景节点。它使用原生 `simplify_path` 清除毫米级数值冗余，以单向游标推进；越过到达圆后，只在向前接回路线的完整通行检查成立时跳过旧点。必要绕墙的折点仍然保留。每次采样最多检查 12 个后续候选折点，另做一次终点直达检查；已经进入最后一段时不会继续重复这些无效检查。

单位请求速度限制为这一物理步内能够走到路点的距离，避免满速跨过短路点。等待路径时保持原有朝向，不直接根据墙另一侧的目的地转身。实际 RVO 避碰与物理碰撞仍可造成合法的横移、减速或小幅退步，因此“直达时没有回追路点”不应被解释成“任何情况下都禁止向后移动”。

编队使用前后排序，再对同一排按左右排序，复杂度为 O(n log n)，以实体 ID 处理完全重合的排序键。Shift 连续移动优先使用上一个已计划移动的终点来计算新编队方向。它避免了选择列表导致的无意义换位，但不是一般障碍地图上的全局最优多智能体分配算法。

建筑的逻辑占地版本在同一帧阻止旧路线继续使用；版本检查位于本帧结果缓存之前。新查询等待网格工作线程完成及导航服务器发布下一次地图迭代。空路径继续保持等待地图变化的状态，不当作已到达；取消、死亡与排队去重保留原有代次管理。每物理步最多处理 24 个请求，直线路径也占请求预算，避免大量直达命令瞬间形成无界工作。

**验证结果与边界**

基线为提交 `8df2187`，引擎为本机 Godot `4.6.3.stable.official.7d41c59c4`。为避开并行开发中的工程兵资源缺口，基线和主要回归在独立工作副本执行，运行真实场景、导航服务器、避让与碰撞。

| 场景 | 修改前 | 修改后 |
|---|---:|---:|
| 219 条全身可直达路线，超过直线 1% 的路线数 | 121 | 0 |
| 上述路线的最差计划长度 / 直线距离 | 1.571 | 1.000 |
| 同一 16 单位骑兵复现场景，到达人数 | 18 秒时 7/16 | 约 6.6 秒时 16/16 |
| 上述场景原生搜索次数 | 57 | 8 |
| 新的空地步兵 / 骑兵 / 混编三组 | — | 每组 16/16 到达；可直达时回追路点 0 次 |
| 70 单位真实地图请求 | — | 3 个物理步完成派发；实测约 103 ms |

70 单位测试的三步中分别执行 18、18、16 次原生查询，其余使用直达结果；每步整个路径处理约 2.10–2.27 ms。这是该测试机器、该地图和该次采样的数据，不是完整战斗的 FPS 或最坏情况保证。到达允许保留既有约 0.65 米余量，因此群组实走距离与精确站位直线距离的比值略小于 1 是正常的提前停步。

通过的专项包括：新增移动回归（约 1,000 项，包含逐步预算检查，总数随到达步数变化）、请求预算 94 项、空地图与迟到区域 15 项、真实地图预算 8 项、轻骑兵导航 8 项、战象导航 8 项、采矿接近 192 项、接敌 340 项、追击攻击 536 项。接敌与追击以 `--fixed-fps 120` 加速墙钟运行，测试内部仍分别验证 30/60 TPS，没有降低物理模拟步数。

合入包含工程兵改动的当前工作区后，又完成编辑器导入检查，以及移动回归 1,003 项、请求预算 94 项、空地图恢复 15 项、接敌 340 项，全部通过。该轮的实际指标另外记录在 JSON 的 `merged_workspace_validation` 中。

旧 `construction_navigation_test.gd` 的 7 个失败项涉及过时的建筑 HP、射程、退款和拆除预期，且仍引用已不存在的 `Buildings/EnemyKeep`。旧 `rts_command_queue_test.gd` 有 1 个既有生产预期失败 `one_group_keypress_buys_one_unit`。用未修改的基线代码复测，两份测试分别得到同样的 7 项和 1 项失败；本次没有把它们记为通过，也没有更改游戏经济规则来迁就断言。相关导航封路、重算及拆除重开检查已通过，新移动回归另外独立覆盖了这些生命周期。

复现入口：

```powershell
& 'C:\Program Files\Godot\Godot_console.exe' --headless --path . --script res://tests/movement_navigation_test.gd
& 'C:\Program Files\Godot\Godot_console.exe' --headless --path . --script res://tests/path_budget_test.gd
& 'C:\Program Files\Godot\Godot_console.exe' --headless --path . --script res://tests/path_budget_startup_test.gd
& 'C:\Program Files\Godot\Godot_console.exe' --headless --fixed-fps 120 --path . --script res://tests/engagement_approach_test.gd
& 'C:\Program Files\Godot\Godot_console.exe' --headless --fixed-fps 120 --path . --script res://tests/pursuit_attack_test.gd
```

后续若仍出现复杂障碍之间的宏观绕路，应收集起终点、实际通道和最短路径对照，再比较原生网格搜索、JPS 或 Polyanya；若瓶颈转为大量同目标远程搜索，再比较分块流场。验收应同时记录路径质量、指令延迟、完整物理步耗时、拥堵完成率及建筑更新成本。本次不声称实现了任意障碍地图上的全局欧氏最短路，也不以局部基准替代 500–896 单位完整对局性能验证。

**参考资料目录**（核对日期：2026-09-12）

1. Daniel Harabor、Alban Grastien，2011，[Online Graph Pruning for Pathfinding On Grid Maps](https://ojs.aaai.org/index.php/AAAI/article/view/7994)，AAAI 25(1)，1114–1119，DOI 10.1609/aaai.v25i1.7994。
2. Adi Botea、Martin Müller、Jonathan Schaeffer，2004，[Near Optimal Hierarchical Path-Finding](https://webdocs.cs.ualberta.ca/~mmueller/ps/2004/hpastar.pdf)，作者所在大学保存的论文。
3. Michael Cui、Daniel D. Harabor、Alban Grastien，2017，[Compromise-free Pathfinding on a Navigation Mesh](https://www.ijcai.org/proceedings/2017/70)，IJCAI，496–502，DOI 10.24963/ijcai.2017/70。
4. Elijah Emerson，2013，[Crowd Pathfinding and Steering Using Flow Field Tiles](https://www.gameaipro.com/GameAIPro/GameAIPro_Chapter23_Crowd_Pathfinding_and_Steering_Using_Flow_Field_Tiles.pdf)，Game AI Pro，第 23 章。
5. Jur van den Berg 等，[Optimal Reciprocal Collision Avoidance](https://gamma-web.iacs.umd.edu/ORCA/)，作者项目页、论文及 RVO2 实现入口。
6. Godot Engine，4.6，[Using NavigationAgents](https://docs.godotengine.org/en/4.6/tutorials/navigation/navigation_using_navigationagents.html)、[Using NavigationPathQueryObjects](https://docs.godotengine.org/en/4.6/tutorials/navigation/navigation_using_navigationpathqueryobjects.html)。
7. [OpenRA 固定版本源码](https://github.com/OpenRA/OpenRA/tree/f3ec7f8e1593b482f85fd101652deb740c33dee6)，[0 A.D. 历史版本源码](https://github.com/0ad/0ad/tree/61a3b9507d974084e6badb88a0826bd89a6d5b8b)，[Recoil 固定版本源码](https://github.com/beyond-all-reason/RecoilEngine/tree/05c054cbe2249feda3637cabfe122b75241113e9)，[Godot 参考标签源码](https://github.com/godotengine/godot/tree/35e80b3a8822a9df9be390814b62f44c0a9c69e8)。具体阅读入口与版本限制见上表；机器可读的仓库清单和验证指标保存在同名 JSON。
