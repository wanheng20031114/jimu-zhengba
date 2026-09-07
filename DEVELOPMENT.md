# 灰烬王国 · 实施约定

视觉：暖沙色、象牙石灰墙、深棕木梁、蓝金玩家与锈红敌军，精细低多边形原创模型，真实3D正交战场。
界面：完整战场为主体，左下小地图，底部选中信息与生产操作，右上金币，克制的炭灰金色界面。
动态：角色步态与攻击、器械抛臂与后坐、旗帜/烟尘/建筑瓦解、选择和指令标记。

## 场景与接口
- 坐标：Y 向上，单位面向 -Z；世界区域 x/z -42..42。角色人体约 1.7~2m；骑兵约 2.5m高；器械宽2.0~2.8m。
- 模型交付路径 `assets/models/units/{swordsman,knight,archer,catapult,cannon}.tscn`，Node3D 根节点，有 `set_motion(moving: bool)`、`strike()`、`set_team(team: int)` 方法。原生 AnimationPlayer 或清晰的部件动画。静态网格可合并，关节有命名枢轴，模型必须实际3D。
- 环境模型路径 `assets/models/environment/{headquarters,enemy_keep,barracks,tower,house,ruin,wall,palisade,barrel,crate,tree,rock,well,cart}.tscn`；均 Node3D 根，Y=0 落地。环境组合场景 `scenes/environment.tscn` 保存静态聚落；可攻击建筑位于主场景 Buildings 下。
- 游戏脚本 `scripts/game.gd`，主场景 `scenes/main.tscn`。主场景与 HUD 由 `tools/build_interface.py` 离线生成，修改保存节点时应同步生成器。
- 战斗脚本 `scripts/battle_unit.gd` / `scripts/battle_building.gd` / `scripts/projectile.gd` / `scripts/battle_effect.gd` 分别绑定 `scenes/unit.tscn` / `building.tscn` / `projectile.tscn` / `battle_effect.tscn`。
- 单位根 CharacterBody3D；建筑根 StaticBody3D。单位 @export `unit_type: String`、`team: int`；建筑 @export `building_type: String`、`team: int`。生成之前设置类型与阵营。
- 实体加入 `entities` 和 `units` / `buildings` 组。公开 `hp`, `max_hp`, `team`, `selected`, `alive`, `display_name`, `radius` 属性；公开 `set_selected(value: bool)`, `receive_damage(amount: float, source: Node3D = null)`, `issue_move(destination: Vector3, attack_move: bool = false)`, `issue_attack(target: Node3D)`, `stop()`, `hold()` 方法（后三项只对单位）。
- 单位 stats 放 battle_unit.gd 常量 STATS 字典，费用依次 swordsman45 / archer60 / knight100 / catapult140 / cannon180。友军蓝，敌军红。
- 主场景固定子节点 `Units`, `Buildings`, `Effects`, `NavigationRegion3D`, `CameraRig`。战斗可从 current_scene 获取主场景。主场景方法 `spawn_projectile(source: Node3D, target: Node3D, damage: float, kind: String)`、`spawn_effect(at: Vector3, kind: String, color: Color = Color.WHITE)`、`on_entity_died(entity: Node3D)`。无必要不依赖其他主场景 API。
- 静态地图使用已保存 NavigationMesh；NavAgent3D 路径/避让。建筑占地在主代理制作的导航网格中阻挡。避免每帧全图逐单位复杂搜索；目标搜索间隔约0.35秒。
- 远程弹体在真实攻击释放帧读取模型 `ProjectileSocket` 的全局位置；逻辑伤害计时与 AnimationPlayer 的释放关键帧对齐。
- 场景结构优先 .tscn 保存；不在运行时拼零碎 MeshInstance/Control 节点。必要实例化 PackedScene 可用。
- 所有源码使用 UTF-8；验证进程应自行退出，并用命令核实。不得关闭用户编辑器。

## 原生渲染与输入

- 每个刚性关节使用单个 ArrayMesh 和共享 ShaderMaterial；阵营颜色通过实例参数设置。动画关键帧保存在原生 AnimationPlayer 中。
- HUD 通过六个独立 SubViewport 展示真实模型，静态预览只绘制一次，活动预览以 15 Hz 更新。`scenes/model_previews.tscn` 可直接在编辑器中修改取景。
- 鼠标边缘移动采用 DisplayServer 的客户区物理像素，覆盖宽屏与 4:3 黑边；世界选择和界面输入使用 Godot 自身的视口变换。
- Ctrl + 数字覆盖编队，Shift + 数字合并所选存活友军并去重；数字召回，双按定位。
- 建筑存活时占地不在主导航网格中，摧毁后启用预先保存的独立 NavigationRegion3D 补片，无需运行时重新烘焙。
- Windows 预设与 `tools/build_windows.ps1` 保存了可重复执行的导出步骤。运行时不依赖 Python、美术生成器或测试代码。

## 地图布局（供环境设计遵守）
大本营中心(-22,0,23)，占地9x8；敌要塞(22,0,-24)，占地9x8；敌兵营(9,0,-21)，占地6x5；敌塔(25,0,-7)，占地4x4；敌仓库/兵营(-4,0,-12)，占地6x5。
中央道路沿 x=z*-0.65，从玩家区左下通向敌区右上；主战斗中心(0,0,0)。地图范围-42..42；装饰房屋置两侧，主要通道留宽10米以上。环境碰撞/障碍清单通过 JSON 交付主代理用于烘焙导航。
