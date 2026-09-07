# 灰烬王国 · 原创单位模型

五种模型由 `tools/build_units.py` 离线雕塑并导出，运行时只实例化保存的 Godot 原生场景，不拼接零碎几何。所有模型面向 -Z，Y=0 为地面。没有使用外部付费模型或素材。

| 模型 | 结构 | 三角面 |
| --- | --- | ---: |
| swordsman | 面甲头盔、分层肩甲与腿甲、剑、五边纹章盾、腰包与剑鞘 | 4,268 |
| archer | 蓝布头兜、皮革甲、弓弦、独立待射箭、箭袋与六支羽箭 | 3,680 |
| knight | 披甲骑士、四肢马匹、蹄铁、鞍、蹬、缰绳、鬃尾与蓝金马衣 | 7,728 |
| catapult | 木梁与铁箍、车轮及轮辐、扭力绳、绞盘、抛臂与独立载石 | 6,972 |
| cannon | 中空青铜炮管、箍环、耳轴、轮辐、炮架、尾架、通条和炮弹 | 5,216 |

每个关节内合并为单个原生 ArrayMesh、单个共享 Shader 材质；顶点 RGB 储存线性色，Alpha 储存哑光/金属/阵营类别，着色器不把 Alpha 用作透明度。GLB 显式导出法线，保留全部低多边形切面和三角面。阵营通过 `set_team(0/1)` 设置 MeshInstance3D 的 instance uniform 切换蓝/锈红，金属纹章不受影响，不复制材质。场景直接把 MeshInstance3D 作为命名关节，减少包装节点：剑士 10、弓手 11、骑兵 13、投石车 11、火炮 8 个节点。

原生 `Locomotion` AnimationPlayer 管理待机、步态与轮转；`Attack` 管理攻击。`set_motion(bool)`、`strike()` 为战斗接口；`die()` 暂停两套动画并保持当前姿势。箭矢与载石在实际投射帧隐藏，装填结束后恢复。攻击帧与战斗脚本同步：剑士 0.22 秒、骑士 0.20 秒、弓手 0.27 秒、投石车 0.48 秒、火炮 0.25 秒。

`preview.tscn` 是独立渲染验证场景：生成阵营总览、五种模型近景、攻击近景，并验证步行、释放和死亡暂停后自行退出。`preview.gd` 不用于正式游戏场景。

重建：先执行 `python tools/build_units.py`（依赖 numpy、trimesh、scipy、networkx），由 Godot `--headless --editor --import --quit` 导入 GLB，再用 `--headless --script res://assets/models/units/bake_native_meshes.gd` 烘焙保存 33 个原生 ArrayMesh。保存的 `.res` 已随工程提供，普通运行无需重建。预览应使用 Forward+ 并启用 Vulkan，以验证主项目的实际材质与阴影。
