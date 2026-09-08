# 灰烬王国 · 中世纪乱斗

使用 **Godot 4.6** 制作的原创 3D 即时战略游戏。蓝旗军团穿过沙石镇，进攻敌方兵营、哨塔和要塞；大本营负责即时招募部队。

![战场画面](artifacts/battlefield.png)

## 运行

使用 Godot 4.6.3 或更新的 4.6 版本导入 `project.godot`，等待资源导入完成后按 **F5**（主场景为 `scenes/main.tscn`）。使用 Forward+ 渲染，建议独立显卡。

本机已打包的 Windows 版本位于 `builds/windows/AshenCrown.exe`；分发时使用 `builds/AshenCrown-Windows-x64.zip`，解压后保留 EXE 和 PCK 在同一目录。构建产物不纳入 Git。

安装 Godot 4.6.3 的导出模板后，可运行 `powershell -ExecutionPolicy Bypass -File tools/build_windows.ps1` 重新打包。导出使用项目内的 Windows Desktop 原生预设，默认 Vulkan。

## 玩法

- 五种可操作单位：剑士、弓箭手、骑士、投石车、加农炮。
- 选中大本营后消耗金币立即生产，无生产计时。
- 每秒自动增加 **1 金币**，**F12** 通过 `debug_gold` 输入映射增加 **100 金币**。
- 消灭守军并摧毁四座敌方军事建筑获胜；大本营被摧毁则失败。
- 敌方兵营定时派出援军，摧毁兵营可切断增援；摧毁军事建筑获得 90 金币。
- 连续对同一目标下达攻击命令会保留当前攻击进度；切换目标仍立即响应。

| 操作 | 按键 |
| --- | --- |
| 选择 / 框选 | 左键 / 拖动左键 |
| 追加或取消选择 | Shift + 左键 / 框选 |
| 选择视野内同类单位 | 双击单位 |
| 移动 / 攻击 / 大本营集结点 | 右键 |
| 追加行军路径 | Shift + 右键 |
| 攻击前进 | A，再左键 |
| 停止 / 坚守 | S / H |
| 创建 / 覆盖编队 | Ctrl + 1–9 |
| 追加所选部队到编队 | Shift + 1–9 |
| 召回编队 / 定位编队 | 1–9 / 双按数字 |
| 移动镜头 | 中键拖动、方向键、屏幕边缘 |
| 缩放 / 定位所选部队 | 滚轮 / 空格 |
| 大本营 / 选择全军 | B / G |
| 招募剑士 / 弓箭手 / 骑士 / 投石车 / 炮 | Q / E / R / T / Y |
| 操作说明 / 暂停 | F1 / Esc |
| 隐藏界面 | F10 |
| 全屏 / 静音 | F11 / M |
| 调试金币 | F12 |

## 音效

包含 **54 个 WAV 变体、22 类运行事件**，覆盖五兵种挥击与发射、不同材质命中、炮弹爆炸、步伐、马蹄、车轮、死亡、建筑倒塌、招募和操作反馈。轻石击 `stone_chip` 复用投石命中的三个样本并降低增益。**不播放 BGM**；按 **Esc** 可调整音效音量，**M** 切换静音。

声音结合 [Kenney Impact Sounds](https://kenney.nl/assets/impact-sounds)、[Kenney Interface Sounds](https://kenney.nl/assets/interface-sounds) 和 [Vehicle / Jan Schupke 武器与装备拟音](https://opengameart.org/content/fantasy-weapons-and-apparel-sfx-library) 的 CC0 录音，以及项目自制合成层。原音源、许可和离线重建记录见 [音效来源](assets/audio/CREDITS.md)。

运行时使用 **38 个原生声部**（战斗 24、步伐等拟音 8、界面 6），限制同类连发与同时播放数量，并避免连续使用同一变体。监听点位于镜头所看战场上方，配合距离衰减、战斗总线轻压缩和 Master −1 dB 限峰；不会因 RTS 相机悬在高空而让近处战斗过分微弱。

## 美术与工程

模型均为本项目离线建模脚本制作的真实 3D 网格。单位以原生场景关节及 `AnimationPlayer` 实现动作；建筑、场景道具、碰撞和界面保存为可编辑 Godot 场景。招募栏直接展示游戏内模型，使用缓存的原生 3D 视口；只有活动预览以 15 FPS 更新。

- `assets/models/units/`：五兵种模型、原生关节网格与动作。
- `assets/models/environment/`：建筑、废墟、道路、植被、营地与道具。
- `assets/audio/`：运行音效、CC0 原音源、来源及响度记录。
- `scenes/`：主战场、实体、界面、弹丸与粒子场景。
- `scripts/`：RTS 操作、经济、导航、战斗、界面。
- `tools/`：离线模型、界面与导航作者脚本。
- `tests/`：引擎内功能验证与压力测试。

离线建模脚本使用 Python 3、NumPy、SciPy、trimesh 和 Shapely 2.1+；运行游戏无需 Python。中文界面使用系统中文字体。

## 验证

```text
Godot_console.exe --headless --path . -- --smoke-test
Godot_console.exe --headless --path . -- --ui-smoke
Godot_console.exe --headless --path . --script res://tests/combat_smoke.gd
Godot_console.exe --headless --path . --script res://tests/battle_scenario.gd
Godot_console.exe --headless --path . --script res://tests/navigation_audit.gd
Godot_console.exe --headless --path . --audio-driver Dummy --script res://tests/audio_runtime_test.gd
Godot_console.exe --headless --path . --audio-driver Dummy --script res://tests/shutdown_lifecycle.gd
Godot_console.exe --headless --path . --audio-driver Dummy --script res://tests/audio_pause_boundary.gd
Godot_console.exe --path . --rendering-driver d3d12 --audio-driver Dummy --script res://tests/repeated_attack_test.gd
```

本轮通过主流程 31 项、输入 24 项、重复攻击回归 116 项（D3D12）、音频运行检查 184 项、退出生命周期 49 项和同帧暂停边界 10 项。音频测试通过 Dummy 驱动捕获 Godot Master 总线，覆盖五兵种实际动作链、22 类事件和大量并发请求；该次混合峰值为 −4.24 dBFS。测试没有向系统扬声器播放，也不将数值验证称为人工试听。完整范围见 [验证记录](docs/validation.md)。

音效接入后，以 RTX 3080、1600×900、Forward+ / Vulkan 实际渲染复测：160 人行军平均约 88 FPS，初始 160 人混战平均约 94 FPS、P95 帧耗时约 14 ms，61 项压力检查通过。音频混音使用 Dummy 驱动运行；这些数据不代表所有设备的帧率。默认 Vulkan 来自此前后端对照，方法和阶段差异见 [性能验证](tests/performance_review.md)。
