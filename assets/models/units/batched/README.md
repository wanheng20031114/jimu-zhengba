# 原动作节点的零件批量显示

`tools/build_rigid_batches.gd` 从六类原生单位场景生成这里的代理场景，以及 `scenes/unit_render_batches.tscn`。每个原始 MeshInstance3D 仅变为同路径 Node3D，网格引用移入 `UnitVisual.batch_parts`；所有动画、可见性轨、父子结构和投射物挂点原样保留。原网格二进制资源和已有 LOD 数据没有重建。

`UnitRenderBatches` 在晚于快照插值的渲染回调中，读取可见零件的原生插值世界变换。每类每个零件对应一个可编辑 MultiMesh 节点，使用原始 Mesh 和共享材质。每个实例的自定义 RGB 是线性阵营色，Alpha 是尸体不透明度；原顶点 Alpha 仍用于区分金属、普通材质和涂装。

0.12 的正式 `scenes/main.tscn` 显式选择六类批量模型并启用管理器；空的模型覆盖表仍保留原始场景，供模型肖像和独立场景使用。完整 500 单位对照见 `report/release-0.12-performance.md`。保留网格 LOD 数据不等于保持逐实例 LOD 选择：MultiMesh 使用整批包围盒，剔除和 LOD 粒度可能变粗；提交端使用原单位的 8 米可见性通知框，并严格服从战争迷雾导致的父节点隐藏。死亡模型继续提交，使用不进入透明队列的屏幕网格渐隐。场景退出会立即清除最后提交的槽位。

Godot 4.6.3 Forward+ 在正交镜头下使用固定 `lod_distance=1`，两种实例都经过相同的表面 LOD 分支；该分支使用几何实例节点的尺度，MultiMesh 内每个部件的尺度不单独参与。当前有 LOD 的存活部件尺度约为 1，动态缩放的弓弦没有 LOD，但模型整体缩小时不能据此承诺完全一致。原网格的 `shadow_mesh` 同样保留。另外，原生有 LOD 分支的面数统计未乘 MultiMesh 实例数；报告中的 primitives 下降不能直接作为实际几何开销下降的证据。源码见 [Forward+ LOD 选择与计数](https://github.com/godotengine/godot/blob/4.6.3-stable/servers/rendering/renderer_rd/forward_clustered/render_forward_clustered.cpp#L1071)、[实例 LOD 尺度](https://github.com/godotengine/godot/blob/4.6.3-stable/servers/rendering/renderer_geometry_instance.cpp#L67)。

离线转换验证命令：

```text
Godot --headless --path <实验项目> --script res://tools/build_rigid_batches.gd -- <临时结果.json>
```

转换器验证各动画的零件变换、可见性及挂点。GPU 外观、屏幕外恢复、客户端插值、父节点隐藏、删除当帧和压力性能需要另行验收；转换结果本身不代表性能改进。
