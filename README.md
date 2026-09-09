# 灰烬王国 · 中世纪乱斗

Godot 4.6 原创 3D RTS，采用暖色低多边形模型与 45° 正交视角。快速建立兵营，指挥混编军队，争夺金矿并摧毁敌方基地。支持单人对 Bot、四人 2v2，以及通过上海 ENet/DTLS 中继联机。

![战场画面](artifacts/battlefield.png)

## 运行

用 Godot 4.6.3 导入 `project.godot` 后按 F5，主场景为原生大厅 `scenes/lobby.tscn`。Windows 发布包解压后运行 `windows/AshenCrown.exe`，保持 EXE 与 PCK 同目录。使用 Forward+ Vulkan 渲染。

安装同版本导出模板后运行 `powershell -ExecutionPolicy Bypass -File tools/build_windows.ps1`。输出 `builds/AshenCrown-Windows-x64.zip`；构建产物不纳入 Git。完整操作见 [玩家说明](docs/windows-readme.txt)，联机部署见 [中继文档](server/README.md)。

## 对局

- 1v1 琥珀十字路（96×96），2v2 双谷争锋（128×112）；对称出生、主路与侧路、6/10处永久矿脉。
- 每人开局 1 座大本营、3 农民、320 金币。自然收入每秒 1，采矿每人每 3 秒 +3；每处矿脉共享 6 个位置。
- 大本营只训练农民：50 金币、10 秒，存活与排队合计上限10。兵营与军工厂即时生产军事单位；军事人口上限60，骑士占2、攻城器占3，其余军队占1。
- 训练与研究队列在生产栏上方逐格显示进度，点击指定格子取消并退款。农民建造、Shift 排队、施工接手；学院研究全军攻防 I/II/III，总加成为 +1/+2/+4。
- 近战/远程护甲与类别附伤统一计算。剑克骑、骑切弓；弓箭利用射程，投石克密集阵列，炮克建筑与攻城器。
- 摧毁敌队全部军事建筑及工地获胜。失去大本营仍可重建；全队完工核心生产建筑全失后，军事建筑永久暴露。
- Bot 遵守相同金币、人口、建造、生产、科技与视野；没有免费刷兵或拆楼奖励。

| 操作 | 按键 |
|---|---|
| 选择、框选、同类选择 | 左键、拖动、双击 |
| 移动/攻击/采矿/接手施工/集结点 | 右键目标 |
| 追加任务、连续建造 | Shift + 指派 |
| 攻击前进、停止、坚守 | A、S、H |
| 覆盖编队、追加编队、召回、定位 | Ctrl + 数字、Shift + 数字、数字、双按数字 |
| 视角移动、缩放 | 屏幕边缘/中键/方向键、滚轮 |
| 大本营、全军、空闲农民 | B、F2（或 G）、句点 |
| 操作帮助、菜单 | F1、Esc |
| 统一暂停 | 单机 Esc；联机房主 P |
| 单机调试金币 | F12，+100 |

## 联机与工程

客户端主动连接 UDP 24571，中继只管理房间、身份和转发，房主运行 30 TPS 权威模拟。独立通道的可见快照以每客户端15Hz发送，位置、朝向和攻击动画在120ms时间线插值；丢包时完整快照的实收频率会降低。命令统一校验 owner、序号、资源与人口；客户端不判伤、不产金、不运行 Bot。局内原始消息按受信证书加密，私人密钥不进仓库。

每人独立控制资产，同队共享视野。未探索、已探索与当前可见分开；失去视野的建筑只留下冻结记忆，隐藏敌人的实时数据不会发给普通客户端。普通断线10秒后Bot接管、120秒内可恢复；房主等待30秒，超时中断，无自动迁移。

单位、建筑、科技、地图由 `data/` 原生 Resource 定义。模型、场景、界面均可编辑；生产按钮展示游戏内3D模型，活动预览15FPS更新。单位原生 `AnimationPlayer`、`NavigationAgent3D` 与物理插值保留动作细节。声音使用有界原生声部、分类增益和总线压缩，无BGM；录音许可与生成记录见 [音效来源](assets/audio/CREDITS.md)。

## 验证与重建

以本轮测试为准，旧0.5战役测试保留作历史参考，不适用于已移除的四楼战役规则。

```text
Godot_console.exe --headless --path . --audio-driver Dummy --script tests/balance_matrix_test.gd
Godot_console.exe --headless --path . --audio-driver Dummy --script tests/balance_combat_test.gd
Godot_console.exe --headless --path . --audio-driver Dummy --script tests/skirmish_match_test.gd
Godot_console.exe --headless --path . --audio-driver Dummy --script tests/fog_state_test.gd
python tests/network_runner.py local
python tests/network_game_live_runner.py local
powershell -ExecutionPolicy Bypass -File tools/profile_skirmish.ps1
```

阶段实现与验收记录：[遭遇战实施](docs/skirmish-implementation.md)、[性能实测](docs/performance-0.6.0.md)、[联网验收](docs/network-validation.md)、[发布包完整对局](docs/release-match-validation.md)。标准混编2v2显示帧P95为16.46ms，P99仍24.86ms；最坏280人混战不能锁定60FPS，完整数据与统计边界保留在报告中。

建模脚本为 `tools/build_units.py`、`tools/build_environment.py`、`tools/build_skirmish_maps.py`；离线建模需要 Python、NumPy、SciPy、trimesh、Shapely，运行游戏无需这些依赖。
