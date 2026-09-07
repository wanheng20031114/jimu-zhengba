# 中世纪聚落与建筑资产

这些模型由 `tools/build_environment.py` 离线建模并导出。所有屋瓦、拱门石、窗框、木梁、城垛、旗帜、桶箍和车轮均为实际三维几何；运行时只需实例化保存的场景。

## 接口

- 每个独立模型为同名 `.tscn` 包装同名 `.glb`，根为 `Node3D`，地面为 Y=0，建筑正门朝 +Z。
- 总部包装场景额外实例化两面 `royal_banner.tscn`。旗布是保存的细分 `PlaneMesh`，通过 `banner_wind.gdshader` 做轻微风动，不需要任何场景脚本或运行时节点生成。
- 包装场景子节点 `Architecture` 是 GLB 场景。其直接 MeshInstance3D 子节点按材质组命名，例如 `Stone`、`Timber`、`Roof`、`Metal`、`Fabric`。
- 建筑模型不自行添加战斗逻辑或碰撞，供 `building.tscn` 的 `StaticBody3D` 统一管理。
- 地图组合为 `res://scenes/environment.tscn`，不包含可攻击建筑。
- `Ground/CollisionShape3D` 提供 84×84 米地面，物理顶面为 Y=-0.03；土色分区也是同一高度的连续裁切表面。石板与薄沙覆盖的可见表面不超过 Y=0.05。
- `SolidEnvironment` 为一个 `StaticBody3D`，保存民居、废墟、围墙、栅栏、井、推车及树干的原生 `BoxShape3D` 碰撞。
- 导航障碍表位于 `assets/environment_obstacles.json`。每项同时提供旋转盒的 `position`、`size`、`rotation_y` 和世界轴对齐包围盒 `aabb_min`、`aabb_max`。不要再次对 AABB 应用旋转。
- `model_manifest.json` 记录模型实际包围盒、三角形与合并网格数量。建筑屋檐、旗帜和总部台阶可能超出主要墙体占地。

## 模型

| 模型 | 主要墙体或器具尺寸 | 可辨识细节 |
| --- | --- | --- |
| headquarters | 主占地 8.9×7.7 m；含台阶最深 8.57 m；总高 8.76 m | 双塔、蓝瓦大厅、屋顶钟楼、拱门、阶梯、侧窗、蓝金旗 |
| enemy_keep | 8.8×7.6 m；总高 9.12 m | 四角塔、铁闸门、城垛、红色旗幔、堡垒侧窗与扶壁 |
| barracks | 墙体 5.8×4.6 m；含屋檐 6.72×5.76 m | 木结构、侧窗、逐片屋瓦、烟囱、长矛架 |
| tower | 墙体 3.18×3.18 m；含扶壁宽 4.01 m | 垛口、箭窗、小拱门、旗杆 |
| house | 墙体 4.9×4.2 m；含屋檐 5.82×5.04 m | 外露梁柱、斜撑、四面窗、烟囱、门铰链 |
| ruin | 6.16×4.7 m；高 3.65 m | 断墙、存留拱门、破梁、石块残骸 |
| wall / palisade | 长约 4.6 / 3.92 m | 分层石块与压顶 / 削尖木桩、横梁、束环 |
| barrel / crate | 桶高 1.25 m；箱高 0.97 m | 鼓腹桶板与铁箍 / 板条、斜撑、钉帽 |
| tree / rock | 树高 6.52 m；岩高 1.11 m | 分支与根部 / 非规则切面 |
| well | 宽 3.0 m；高 3.43 m | 分层石井、瓦棚、绞盘、绳与水桶 |
| cart | 宽 2.36 m；含牵引杆长 4.47 m | 木栏板、轮轴、铁轮圈、辐条、牵引杆 |
| tent | 帐体宽 2.84 m、深 3.4 m；含缆绳 4×5.32 m | 帆布拼片、蓝条、敞开门帘、支撑杆、缆绳与地钉 |
| sacks / hay_bale | 粮袋组宽 1.38 m；干草捆 1.72×0.98 m | 缝线、扎口 / 草秆、绳带 |
| campfire | 宽约 1.65 m、高 1.5 m | 石圈、交错柴木、三脚架、悬挂炊锅 |
| broken_wheel / broken_shield | 宽约 1.1 / 0.9 m | 缺口轮圈、断辐条 / 缺损木板、残留红漆、金属盾脐 |

## 美术与性能

- 建筑每个 GLB 最多 5 个合并网格；地图细节合并为 5 个网格，土面与石板合并为 2 个网格。总部另有两面原生风动旗布。
- 每种表面保留顶点色，导出时将调色板的 sRGB 转换为 glTF 要求的线性 RGB。
- GLB 显式包含 `NORMAL` 和 `COLOR_0`。石木材质粗糙度 0.84；金属金属度 0.65、粗糙度 0.38。
- 总部和敌堡分别约 20.5k / 14.2k 三角形；连续错缝石板路与地面约 41.2k，世界道具约 89.6k。
- 主道路宽约 6.2 m，沙灰色石板带暗缝，边缘由薄沙层局部覆盖。物理仍为平地，主通道和两端入口均避开树干障碍。
- 两顶补给帐篷位于 (-30.1, 19.1)、(-14.6, -24)，其余粮袋、干草和火架均置于侧边院落，远离初始军队位置。
- 不需要运行时生成装饰节点或重新建模。离线依赖为 Python、NumPy、trimesh、Shapely 2.1+；修改模型后运行 `python tools/build_environment.py`，随后让 Godot 正常重新导入 GLB。导出仅在内容改变时原子替换文件，避免编辑器自动导入写入中的半个模型。
- 重新生成会同步更新导航障碍 JSON；烘焙导航应在环境重建后执行。
- 地形和聚落分别使用独立的随机数序列；继续细化道路不会改变树木及障碍的位置。

## 检查场景

`preview.tscn` 是独立的三维美术检查场景。启动后会保存全图、总部、敌堡截图并自动退出；它不属于正式游戏运行入口。截图位于本目录的 `preview_battlefield.png`、`preview_headquarters.png` 与 `preview_keep.png`。

采用的原生能力依据：[Godot 3D 场景导入](https://docs.godotengine.org/en/stable/tutorials/assets_pipeline/importing_3d_scenes/import_configuration.html)、[Godot 3D 碰撞形状](https://docs.godotengine.org/en/stable/tutorials/physics/collision_shapes_3d.html)。

## 表面稳定性

屋瓦与坡面同向并留实际灰缝；房屋梁柱采用前后错层或端头对接；塔顶木板高于石平台 4.5 cm；窗棂与窗框、百叶铁带各自有明确深度。井沿使用不重叠的楔形石，车轮辐条从轮毂边缘开始，篱笆束带错开接缝。静态旗帜、帐篷与草叶只保留一张几何面，由原生双面材质显示背面；王旗最低摆动位置与墙体仍有间隙。导出时按坐标去掉完全重复或退化的三角形，保持独立顶点色与硬边法线。

`audit_surfaces.py <标签>` 会检查全部 20 个独立模型与地形，寻找正面积的同向共面三角形重叠，区别于仅共享边的相邻三角形和不可见内部反向接合。结果保存在 `artifacts/environment_flicker/surfaces_<标签>.json`。

`flicker_review.tscn -- <标签>` 使用真正的 GPU 渲染，对总部、敌堡、房屋、废墟、塔顶和道路各保存 12 帧微幅平移及 12 帧环绕镜头，并自动退出。使用主场景的阴影偏移 0.06 / 法线偏移 2.0。`compare_frames.py` 将 before/final 的微幅镜头运动配准后统计帧残差；旗布动画、TAA 和软阴影仍会贡献少量变化，因此该统计需结合几何审计与实际帧目检解读。
