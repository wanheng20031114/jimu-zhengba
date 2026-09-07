# 离线导航与拆毁补片

执行 `python tools/build_navigation.py`，或从作者工具导入并调用 `build_navigation.build()`。必须在 `scenes/main.tscn` 保存后执行，因为建筑、初始单位位置直接读取该场景。环境几何、碰撞和 `assets/environment_obstacles.json` 更新后也应重新运行。

作者脚本生成：

- `assets/battle_navigation.tres`：避开 5 栋战斗建筑和全部 93 个环境障碍的主网格。
- `assets/navigation/{Headquarters,EnemyKeep,NorthBarracks,Watchtower,WestBarracks}_cleared.tres`：建筑拆毁后启用的独立补片。
- `assets/navigation/audit_manifest.json`：网格统计、连通域、路径测试点，以及每个初始单位的碰撞、导航和建议坐标审查。

## 场景接口

- 全部导航顶点是世界坐标，使用同一套 X/Z 整数一米格，Y 固定 0.03。
- 所有对应 `NavigationRegion3D` 的全局变换都必须保持单位变换，位置 `(0,0,0)`、旋转 `(0,0,0)`、缩放 `(1,1,1)`。如果直接作为有位移的建筑子节点，需要抵消父变换；优先统一放到无变换的容器节点下。
- 主区域默认启用，五个补片区域默认 `enabled = false`，同属 `navigation_layers = 1`，保留 `use_edge_connections = true`。
- 建筑死亡、实体碰撞解除后，启用同名 `_cleared` 补片区域即可。无需重新烘焙、移动顶点或添加 NavigationLink3D。
- 补片仅含被该建筑独占阻挡的格子；被环境或其他存活建筑阻挡的格子不会被补回。补片和主网格互不重叠，公共边的两个端点完全相同。

## 作者规则

导航范围 `[-40,40] × [-40,40]`，保留地图外围两米边距。按原作者规则，以格子中心判断是否落入障碍包围盒，所有障碍在 X/Z 两方向扩展 1.15 米。环境旋转盒先转换为世界 AABB，只旋转一次。NavigationMesh 的元数据保持 `agent_radius=0.75`、`cell_size=0.25`、`cell_height=0.25`。

主网格目前 4,666 格，其中主连通区 4,658 格。外围还有 3、3、2 格的孤立小口袋，不含出生点。补片格数：总部 106、敌堡 120、北兵营 64、哨塔 36、西兵营 64。

## Godot 实测

运行：

`Godot_console.exe --headless --path . --script res://tests/navigation_audit.gd`

测试直接加载以上实际资源，使用原生 NavigationRegion3D 和 NavigationServer3D。验证共享顶点、非重叠格子、主战场路径、每个补片的启用/禁用、实际穿过原址、同时启用全部补片等 72 项。测试将边缘连接容差压到 0.001 米，确保成功来自一致网格而非宽松连接半径。

Godot 4.6.3 实测中，`map_get_closest_point()` 可能返回禁用区域上的点；它不能单独证明可达性。是否能进入该位置应检查实际 `map_get_path()` 结果是否到达目标。首次加载大网格时也应等待区域完成同步，首个地图 iteration 本身不保证所有异步区域已上传。测试场景使用同步区域上传，生产场景可保持异步上传。

依据：[NavigationServer3D 同步与共享边说明](https://docs.godotengine.org/en/stable/classes/class_navigationserver3d.html)、[原生 NavigationRegion 使用方法](https://docs.godotengine.org/en/stable/tutorials/navigation/navigation_using_navigationregions.html)。

## 初始出生点审查

首轮审查 14 个蓝方单位无障碍重叠且处于主连通区。7 个红方单位需要调整；其他单位之间没有胶囊碰撞体重叠。

| 名称 | 原 X/Z | 建议 X/Z | 原因 |
| --- | --- | --- | --- |
| Red25 | 18, -15 | 15.5, -15.5 | 与 Cart11 实际重叠 |
| Red26 | 19.7, -15 | 22.5, -14.5 | 与 Cart11 实际重叠 |
| Red27 | 21.4, -15 | 23.5, -13.5 | 位于导航避让区 |
| Red28 | 18, -16.5 | 17.5, -17.5 | 位于导航避让区 |
| Red29 | 19.7, -16.5 | 24.5, -16.5 | 与 Palisade25 实际重叠 |
| Red30 | 21, -18 | 24.5, -14.5 | 位于导航避让区 |
| Red31 | 22.5, -18 | 25.5, -15.5 | 位于导航避让区 |

这些建议避开了环境和其他初始单位。主场景调整后运行 `python tools/build_navigation.py --strict-spawns`，如还有碰撞或不可达出生点，将返回非零退出码。最新状态以重新生成的 `audit_manifest.json` 为准。
