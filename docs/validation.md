# 验证记录 · 2026-09-08

使用 Godot 4.6.3、Windows x64。测试通过原生场景、物理、导航和输入管线运行；真实渲染验证使用 RTX 3080。验证不发送桌面输入。

## 本轮：重复攻击指令与音效

| 范围 | 结果与依据 |
| --- | --- |
| 五兵种重复攻击、出手前后连点、切换目标与队列 | D3D12 渲染运行 116 项通过；`artifacts/repeated_attack_after.json` |
| 22 类声音事件、五兵种实际动作链、三类移动拟音、并发限制与音量操作 | 184 项通过；`artifacts/audio_runtime.json` |
| 停播实例释放、暂停后重开、暂停时关闭窗口 | 49 项通过；`artifacts/shutdown_lifecycle.json` |
| 同帧播放后立即暂停、恢复待播声、关闭待播引用、变体抽样 | 10 项通过；`tests/audio_pause_boundary.gd` |
| 经济、F12、即时生产、编队、死亡与胜利 | 31 项通过；`artifacts/integration-results.json` |
| 原生鼠标和键盘输入、招募、框选、指令与暂停 | 24 项通过；`artifacts/ui-input-results.json` |

音效库为 54 个 WAV、21 类素材，运行时增加复用投石样本的轻石击 `stone_chip`，共 22 类事件。81 份原始录音逐字节对照下载包核验，54 个成品离线重建后的 SHA-256 全部一致；许可与来源见 [CC0 音源记录](../assets/audio/CREDITS.md)。项目不含 BGM 播放，Esc 提供音效音量滑块，M 切换静音。

音频采用 38 个固定原生声部、变体轮换、同类限流、战斗总线轻压缩与 Master −1 dB 限峰。监听点设在战场上方 6 m，使用距离衰减；避免高位 RTS 相机令可见近处音效过弱。Dummy 音频驱动下捕获实际 Master 混音，大量并发事件请求的该次峰值为 **−4.24 dBFS**，无削波。这是游戏内部混音测量，没有向系统扬声器播放，也不代表已完成人工试听。

```text
Godot_console.exe --headless --path . --audio-driver Dummy --script res://tests/audio_runtime_test.gd
Godot_console.exe --headless --path . --audio-driver Dummy --script res://tests/shutdown_lifecycle.gd
Godot_console.exe --headless --path . --audio-driver Dummy --script res://tests/audio_pause_boundary.gd
Godot_console.exe --path . --rendering-driver d3d12 --audio-driver Dummy --script res://tests/repeated_attack_test.gd
Godot_console.exe --headless --path . -- --smoke-test
Godot_console.exe --headless --path . -- --ui-smoke
```

本轮另做一次 Forward+ / Vulkan、1600×900、关闭 VSync 的实际渲染压力检查，61 项通过，日志无错误，全部采样孤儿节点为 0。160 友军行军平均 87.7 FPS；初始 160 人混战平均 94.3 FPS、P95 13.8 ms，采样平均存活 147.9 人。使用 Dummy 音频驱动，游戏声音事件、声部与混音仍运行；该数据不代表所有设备的性能。记录：`artifacts/audio-stress-vulkan.json`。

Windows 0.3.0 原生发布包已重新导出；实际运行 `AshenCrown.exe` 使用默认 Vulkan，成功加载战场、保存画面并正常退出，标准错误为空。ZIP 内 PCK 与导出目录的 SHA-256 相同。原始音源目录与验证产物不进入发布包，导出日志无警告；验证辅助进程已通过 Win32_Process 核实退出。

## 此前首次交付阶段

下列美术、导航、窗口和 FPS 检查来自音效重构前的阶段，不作为本轮重新运行的结果。

| 范围 | 结果 |
| --- | --- |
| 战斗、释放帧、真实武器挂点、弹体方向 | 39 项通过 |
| 剑士/骑兵从建筑四面及四角接近、命中、碰撞、后续路径 | 51 项通过 |
| 实际推城获胜、建筑残址通行、大本营被毁失败 | 8 项通过 |
| 原生导航网格、各建筑独立补片、全部补片 | 72 项通过 |
| 实际模型预览、透明背景、取景、仅活动视口更新 | 55 项通过 |
| 五兵种动画、拉弦接触、回收、死亡暂停 | 39 项通过 |
| 模型可重建与原生资源一致性 | 43 个源文件一致，360 项资源检查通过 |
| 建筑与道具表面 | 21 项几何审计，无同向共面重叠或重复三角；144 帧镜头检查 |
| 窗口布局与点击映射 | 1280×720、1920×1080、1280×960、2560×1080 均通过 |
| 正式战斗画面 | 原有 14 人部队通过正常指令交战，五类动画、三类弹体、实际建筑倒塌均已捕捉 |
| 压力与生命周期 | D3D12、Vulkan 各 61 项通过；零孤儿节点，退出日志无错误 |
| Windows 发布包 | 原生导出成功，连续 5 次启动、截图、退出无资源泄露 |

历史性能细节与本轮结果见 [性能记录](../tests/performance_review.md)；本轮未重复完整后端对照。窗口黑边不参与世界坐标计算；边缘移动使用完整客户区的物理像素，覆盖四条外边缘与四个角。

可重复使用的脚本保存在 `tests/`。截图、日志和大部分运行记录写入被 Git 忽略的 `artifacts/`，美术与性能数据保留其阶段说明。Windows 导出不包含测试、离线生成器或检查场景。

原生方案参考：[SubViewport](https://docs.godotengine.org/en/4.6/classes/class_subviewport.html)、[DisplayServer 客户区坐标](https://docs.godotengine.org/en/4.6/classes/class_displayserver.html)、[阴影偏移](https://docs.godotengine.org/en/4.6/tutorials/3d/lights_and_shadows.html)、[Windows 导出](https://docs.godotengine.org/en/4.6/tutorials/export/exporting_for_windows.html)。
