# 中世纪战场与建筑资产

这些模型由 `tools/build_environment.py` 离线建模并导出。屋瓦、拱门石、窗框、木梁、城垛、旗帜、矿石、树枝和施工脚手架均为实际三维几何；运行时实例化保存的场景。

## 当前地图与接口

- 每个独立模型为同名 `.tscn` 包装同名 `.glb`，根为 `Node3D`，地面为 Y=0，建筑正门朝 +Z。正式战场使用 45° 正交镜头，不通过扭曲模型制造视角。
- 包装场景子节点 `Architecture` 是 GLB 场景。直接 MeshInstance3D 子节点按材质组命名，如 `Stone`、`Timber`、`Roof`、`Metal`、`Fabric`。
- 总部额外实例化两面 `royal_banner.tscn`；保存的细分 PlaneMesh 与 `banner_wind.gdshader` 提供轻微风动。
- 军事建筑模型不自行添加逻辑或碰撞，由 `scenes/building.tscn` 的 StaticBody3D 管理。
- 正式环境组合为 `scenes/environment.tscn`。无功能民居、废墟、围墙、栅栏、井、推车和补给营帐已从地图移除，换成侧翼岩石与树木；五座初始军事建筑仍由主场景管理。
- `NaturalObstacles` 保存 14 处岩石与 14 棵侧翼树木，边界树林与地表细节合并到 `world_details.glb`。树冠不阻挡整个投影面积，树干有碰撞。
- `Ground/CollisionShape3D` 提供 84×84 米地面，物理顶面 Y=-0.03；土色分区为同高度的连续裁切表面。石板与薄沙的可见表面不超过 Y=0.05。
- `SolidEnvironment` 保存 73 个自然障碍的原生 BoxShape3D 碰撞。矿脉由 `scenes/resource_vein.tscn` 单独管理，环境不会重复实例化其模型或碰撞。
- `assets/environment_obstacles.json` 同时提供旋转盒的 `position`、`size`、`rotation_y` 与世界包围盒 `aabb_min`、`aabb_max`，不要再次旋转 AABB。标记 `resource: true` 的五项是矿脉导航与建造占地，`resource_veins` 给出主场景资源坐标。
- `model_manifest.json` 记录实际包围盒、三角面与合并网格数量。老建筑的屋檐、旗帜和总部台阶可能超出主要墙体占地。

五处金矿中心为 `(-31,17)`、`(-9,27)`、`(-17,2)`、`(9,3)`、`(31,-19)`，顺序为 X、Z，模型及碰撞半径预算 2.2 m。矿边额外 0.8 m 工作带与自然障碍无包围盒冲突。

## 当前主要模型

| 模型 | 实际三角面 | 可辨识细节 |
| --- | ---: | --- |
| headquarters | 20,494 | 双塔、蓝瓦大厅、钟楼、拱门、阶梯、侧窗、蓝金旗；总高 8.76 m |
| enemy_keep | 14,244 | 四角塔、铁闸门、城垛、红旗幔、堡垒侧窗与扶壁；总高 9.12 m |
| barracks | 13,608 | 木结构、侧窗、逐片屋瓦、烟囱、长矛架 |
| tower | 3,156 | 原敌军哨塔，垛口、箭窗、小拱门、旗杆 |
| defense_tower | 5,364 | 蓝旗、石垛口、木平台、内置重弩、弩弦及待射弩矢；总高 5.98 m，位于 4×4 m 占地内 |
| scaffolding | 2,444 | 四角木柱、横梁斜撑、绳箍、脚手板、梯子、低石基、堆料与施工图板；总高 3.82 m |
| gold_vein | 1,526 | 深灰破碎岩体、贴合实际岩面的立体露金层、金晶簇、碎矿；总高 1.96 m |
| rock_large / rock_medium | 各 502 | 宽切面、不规则岩组、苔斑与碎石；高 2.89 / 1.85 m |
| tree_oak | 1,060 | 主干、根部、树皮纹理、枝结、分枝与不规则阔叶冠；高 6.06 m |
| tree_pine | 648 | 根部、主干、错落针叶层、枝梢与尖顶；高 5.56 m |

此前制作的 `house`、`ruin`、`wall`、`palisade`、`well`、`cart`、`tent`、桶箱及营地小物等源资产仍保留，便于离线复用；它们不作为本轮地图中的无功能障碍。

## 建造显示

`defense_tower.tscn` 在四个合并网格上保存 ShaderMaterial 覆盖，使用 `construction.gdshader`，保留顶点色与对应石木/金属粗糙度。建筑脚本设置原生实例参数 `construction_progress`（0–1），按模型本地高度逐层显露石墙，避免缩放整座建筑；脚手架由建筑场景切换显隐。模型不会自行计时、扣金币或管理施工者。

材质设为双面，允许显示旗帜背面与未完成石墙的内部。该参数默认 1，因此单独打开模型或显示完成塔时呈现完整雕塑。建造计时、单施工者、接手、取消退款与完工攻击由建筑和农民逻辑负责。

## 美术与性能

- 军事建筑每个 GLB 最多 5 个合并网格；新塔 4 个、脚手架 3 个、每种岩树与矿脉 2 个。世界地表装饰合并为 3 个网格，土面与石板合并为 2 个，总部另有两面风动旗布。
- 每种表面保留顶点色，导出时将调色板 sRGB 转换为 glTF 线性 RGB。GLB 显式包含 NORMAL 和 COLOR_0；石木粗糙度 0.84，金属金属度 0.65、粗糙度 0.38。
- 当前地面与道路为 39,084 三角面，合批装饰为 80,552；旧地图合批装饰为 89,612。几何规模比较不代表本轮帧率测量，性能结果以项目验证记录为准。
- 主道路宽约 6.2 m，沙灰色石板有暗缝，边缘局部薄沙覆盖。中央大道、出兵位置、矿周围工作区与可建造空地保持连通。
- 无运行时生成装饰网格。离线依赖 Python、NumPy、trimesh、Shapely 2.1+；修改模型后运行 `python tools/build_environment.py`，随后让 Godot 重新导入 GLB。导出只在内容改变时原子替换，避免编辑器读入未完成文件。
- 重建会同步更新导航障碍 JSON；导航生成应在环境重建后执行。地形和布局使用独立随机数序列，旧军事模型不受新自然素材生成影响。

## 检查与表面稳定性

本轮新模型使用实际 Vulkan 视口检查，包括农民工作时工具切换与防御塔建造高度裁剪，共 19 项通过；本机截图位于 `.local/model_review/`，完整范围见项目 `docs/validation.md`。素材导入、烘焙、视口检查日志没有错误。该项检查不测量整场战斗帧率。

屋瓦与坡面留有实际灰缝，梁柱错层或端头对接，窗框等细部有明确深度。矿脉露金轮廓按岩体真实切面生成，并有明确体积，避免埋进岩体或同面重叠。导出删除完全重复或退化三角形，保留独立顶点色与硬边法线。

保留的 `preview.tscn`、`audit_surfaces.py`、`flicker_review.tscn` 与 `compare_frames.py` 是早期聚落美术审查工具；此前 21 项表面审计和 144 帧镜头检查属于历史交付阶段，不能作为本轮新增七种环境模型已通过同一完整审查的依据。正式运行入口仍为主场景。

原生能力参考：[Godot 3D 场景导入](https://docs.godotengine.org/en/stable/tutorials/assets_pipeline/importing_3d_scenes/import_configuration.html)、[Godot 3D 碰撞形状](https://docs.godotengine.org/en/stable/tutorials/physics/collision_shapes_3d.html)。
