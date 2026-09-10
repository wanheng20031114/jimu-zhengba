# 原生刚体蒙皮实验

本目录六种模型是原始 `../<单位名>.tscn` 的派生运行模型，原始艺术资源保持不变。离线转换器为 `tools/build_rigid_skin.gd`，运行示例：

```text
Godot.exe --headless --path <项目目录> --script res://tools/build_rigid_skin.gd --log-file <独立日志路径> -- <结果JSON路径> swordsman
```

单位名支持 `swordsman`、`archer`、`knight`、`catapult`、`cannon`、`farmer`，省略时为剑士。场景保留原生可编辑 Skeleton3D、Skin、ArrayMesh、AnimationPlayer、BoneAttachment3D 和 SkeletonModifier3D。骨骼保留原始 Rig/Action 层级，每个合并网格顶点以权重 1 绑定原刚体零件，顶点数、三角形顺序、法线与顶点色不变。

| 单位 | 原节点→新节点 | 原网格→新网格 | 骨骼 | 保留可见性附件 |
|---|---:|---:|---:|---|
| 剑士 | 14→9 | 6→1 | 10 | 无 |
| 弓箭手 | 19→11 | 11→2 | 15 | 箭 |
| 骑士 | 18→9 | 10→1 | 14 | 无 |
| 投石车 | 18→11 | 7→2 | 14 | 载荷 |
| 加农炮 | 13→9 | 4→1 | 9 | 无 |
| 农民 | 18→13 | 10→3 | 14 | 镐、锤 |

这些节点数不包含公共 BattleUnit 层级，网格数不能直接等同 GPU draw call 数。Forward+ 原模型可能已经自动实例化；是否节省整场 CPU 时间必须实际测量。

模型沿用 UnitVisual 的 Rig、Locomotion、Attack、VisibilityNotifier 节点名。`rigid_skin_skeleton` 和 `rigid_skin_socket_bone` 明确指定骨骼挂点。权威出手在采样攻击动作后直接读取 `Skeleton3D.get_bone_global_pose()`，不依赖附件的延迟变换通知。

转换器验证保存前及重新读取实际资源后的全部顶点、法线、顶点色、UV（存在时）、三角形索引和刚体权重。采样覆盖待机、行走、攻击关键帧、出手附近中间帧、连续 30 TPS 行走／待机交叉混合和同时攻击。农民增加建造和采集；所有可见性轨覆盖关键时间前、关键时间及之后。每类 164～236 个姿态，使用非零父位置与旋转验证世界空间。附件通过实际原生 BoneAttachment 更新检查，并保留原始网格资源。生成错误会使工具以非零状态退出。

Godot 4.6.3 的 Skeleton3D 不会自动插值每根骨骼。`scripts/rigid_skin_interpolator.gd` 通过原生 modifier 的备份／恢复流程只改变显示姿态：30 TPS AnimationPlayer 不变，出手与计时不变；每次原生 `pose_updated` 采样，同一物理步的晚 Timer 只更新 current。屏幕外暂停 modifier 自动回调，MANUAL 客户端不重复插值。静态骨骼不写回。可见性附件关闭自身的 Node3D 插值，跟随已经插值后的骨骼。

2026-09-10 小场景验证：剑士 30 TPS／60 帧上限下直接读取 RenderingServer 实际 skin 矩阵，2231 项通过；44 对同一物理步内的相邻渲染帧具有不同中间姿态。覆盖重复 modifier 提交、晚 Timer、隐藏恢复、暂停及 MANUAL。六类共存的 Vulkan Forward+ 160 帧验证 20700 项通过，skin 矩阵最大误差 7.16×10⁻⁷、附件最终变换最大误差 4.92×10⁻⁷；原生恢复的权威姿态正确。目视检查原／新模型成对截图，形状与阵营染色一致。

上述小场景与转换验证不代表整场性能通过。正式发行目录保持不变，实验模型是否启用由独立的选择开关控制；全军性能消融后才决定是否采用。
