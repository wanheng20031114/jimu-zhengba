# 验证记录 · 2026-09-09

使用 Godot 4.6.3、Windows x64。测试通过原生场景、物理、导航和输入管线运行；真实渲染验证使用 RTX 3080。验证不发送桌面输入。

## 本轮：0.5.0 固定模拟、插值与性能

默认物理频率为 30 TPS，原生插值平滑单位、关节和弹丸。镜头、框选、预览和命令反馈保留显示时钟；攻击前摇、经济 Timer 和倒地/倒塌 Tween 统一为物理时钟。持续攻击保留跨步余数；普通移动每步只推进一次导航路径。完整设计见 [模拟架构](simulation-architecture.md)。

| 已完成范围 | 结果与依据 |
| --- | --- |
| 30/60 TPS 下实际一分钟的攻击次数、相位误差、采矿收益与闲置不积存攻击 | 46 项通过；`tests/unit_motion_timing_test.gd` |
| 采矿/建造边界、基础收入、暂停，以及两个物理步之间的命令反馈与状态归属 | 40 项通过；`tests/fixed_step_contract_test.gd` |
| 原生显示插值、出手挂点、真实弓手连点/转向/取消/目标删除后重新攻击 | 30/60 TPS 分别 134 项通过；`tests/physics_interpolation_visual_test.gd` |
| 73 个独立障碍碰撞体的世界变换、形状、层、材质与保存结构 | 367 项通过；`tests/environment_collision_audit.gd` |
| 镜头边角、最大/最小缩放、16:9/21:9/32:9 的阴影与裁剪范围 | 107 项通过；`tests/shadow_camera_audit.gd`，另有 10 张渲染画面 |
| 共享选中圈资源、独立阵营色、尺寸/可见性及血条保持原行为 | 22 项通过；`tests/unit_selection_material_test.gd` |
| GPU 尘土六类单位的移动、停止、撞墙、离墙、死亡与持久节点生命周期 | 195 项通过；`tests/movement_dust_test.gd`，无头验证原生状态，实际画面另查 |
| 胜利、失败、退出同一调用内停止尘土/行走、清理工人和攻击订单，尾迹自然消散 | 58 项通过；`tests/unit_shutdown_lifecycle_test.gd`，另重跑计时 40 + 46 项通过 |
| 农民与军事 AI、施工和导航、真实经济输入回归 | 82 + 47 + 47 项通过；六项计时及玩法测试 stderr 均为空 |
| 原有军事模型作者资源一致性 | 360 项通过，43 个源文件逐字节一致；没有改变网格或动画关键帧 |
| 最终 Vulkan 渲染回归：重复攻击、动作、模型肖像、经济/编队主流程、原生输入 | 116 + 39 + 80 + 32 + 24 项通过，退出码均为 0、stderr 均为空 |
| 正式初始部队实战、五种攻击动作、三种弹丸、攻城与倒塌 | 7 项通过、8 张实战截图；`tests/battle_visual_capture.gd`，已查看近战与攻城画面 |

弓箭质量按实际 BattleUnit 发射事件区分蓄力与放弦，避免把已发射的显示插值帧误判为扣弦。30 TPS 最后一次采样发射前手/弦接触误差 P95 约 0.971 cm，与作者姿态的误差量级一致；首个弹丸显示帧没有重复手持箭，未引入额外动画调度结构。

实际删除目标节点的回归发现 GDScript 参数类型检查会先于有效性检查处理已释放引用；有效性检查入口改接收 Variant，沿用原来的存活与阵营条件。删除目标后单位恢复待命，随后仍能正常接令并造成伤害。

```text
Godot_console.exe --headless --path . --audio-driver Dummy --fixed-fps 120 --script res://tests/unit_motion_timing_test.gd
Godot_console.exe --headless --path . --audio-driver Dummy --fixed-fps 120 --script res://tests/fixed_step_contract_test.gd
Godot_console.exe --path . --audio-driver Dummy --script res://tests/physics_interpolation_visual_test.gd -- --tps=30
Godot_console.exe --path . --audio-driver Dummy --script res://tests/stress_test.gd -- --tps=30
```

最终连续性能对照中，旧版→当前版的 160 人行军为 69.5→86.5 FPS，初始 160 人混战为 72.3→84.2 FPS；两次 61 项压力检查全部通过。测试时另一个用户 3D 程序仍在运行，未关闭用户程序；混战 P95 为 17.57→18.60 ms，不能据平均值声称消除了长帧。未经筛选的运行数据、条件变化和中间版本均归档在 [本轮统计](../tests/performance_0_5_0.json) 与 [性能记录](../tests/performance_review.md)。

### Windows 0.5.0 成品验证

原生导入与 Windows Desktop 发布导出均退出码 0、stderr 为空，日志无错误或警告，验证脚本未进入资源包。EXE 文件版本为 `0.5.0.0`。实际运行导出的 `AshenCrown.exe --audio-driver Dummy -- --capture`，默认 Vulkan 成功加载战场、保存画面并正常退出，stderr 为空；已查看该发布版画面并更新仓库截图。

ZIP 为 45,805,502 字节，逐项核对 EXE、PCK 和说明文档，压缩包与导出目录的 SHA-256 全部一致。PCK 为 11,492,596 字节，SHA-256：`44aba695b0b3a01d4ca2386ec6666f4d6255f1f7d71f7745362ba200e261397c`。本机包为 `builds/AshenCrown-Windows-x64.zip`，构建产物按规则不纳入 Git，可用 `tools/build_windows.ps1` 重建。

结束前以 Win32_Process 命令核实：Godot 无头、检查、导入、压力测试、发布版截图和本轮打包辅助进程均已退出；用户其他程序保持运行。

## 历史阶段：0.4.0 农民、矿脉、防御塔与军事待命 AI

本轮面向 0.4.0：初始两名农民、50 金币即时招募、无限矿脉每人 3 秒结算 3 金币，提供采集与建造进度条。Shift 可混合追加移动、采矿和建造；采矿完成当前周期后执行后续队列，最后一项采矿持续循环。中断采矿不结算未完成周期，重复矿脉命令保留进度。

防御塔每座 100 金币，由一名抵达现场的农民累计施工 20 秒；多人不能叠加速度，离开或死亡后可由其他农民接手，保留施工进度。Delete 取消未完成工地，按剩余比例向下取整退款；普通 Delete 不拆完成塔，Ctrl + Delete 拆除自家完成塔且无退款。完成塔自动攻击、不接受驻军。双方军事单位待命时主动追击周围敌人，坚守命令仍保持位置。

| 已完成范围 | 结果与依据 |
| --- | --- |
| 五军事类型、双方阵营的待命发现、追击、造成伤害与重新索敌；农民步行采矿、3 秒周期、重复命令、暂停及任务队列 | 82 项通过；`tests/worker_ai_test.gd` |
| 20 秒施工、单施工者与接手、取消退款、完工射击、建筑占地及拆除后的导航 | 47 项通过；`tests/construction_navigation_test.gd` |
| 实际主场景与原生输入：招募、采矿入账、Shift双塔、退款与拆除、矿脉集结、出生点阻挡及恢复 | 47 项通过；`tests/economy_input_test.gd` |
| 经济、F12、六类即时招募、编队与胜负主流程 | 32 项通过；`artifacts/integration-results.json` |
| 实际原生鼠标、框选、编队、镜头边缘和军事指令 | 24 项通过；`tests/ui_input_test.gd`，Vulkan渲染 |
| 四种窗口比例的六类招募、农民建造面板、模型预览和点击位置 | 2,366 项通过；`tests/hud_resize_test.gd`，1280×720、1920×1080、1280×960、2560×1080 |
| 九种模型肖像、透明视口及仅活动预览更新 | 80 项通过；`tests/model_previews_test.gd`，Vulkan渲染 |
| 五军事类型的重复攻击指令、切换目标、取消出手与失效目标 | 116 项通过；`tests/repeated_attack_test.gd`，Vulkan渲染 |
| 新地图与各军事建筑导航补片 | 原生导航审计 72 项通过；`tests/navigation_audit.gd` |
| 原有五军事类型模型重建 | 360 项通过，43 个源文件字节一致；`tests/model_rebuild_audit.json` |
| 农民原生动作、工具切换、步行转采集、塔的四个保存材质与施工裁剪 | Vulkan 实际视口 19 项通过；本机 `.local/model_review/checks.json` 与对应截图 |

模型原生导入、农民 ArrayMesh 烘焙及素材视口检查的标准错误均为空。新增农民为 10 个刚性网格、4,076 三角面；矿脉 1,526，防御塔 5,364，脚手架 2,444 三角面。橡树、松树、大小岩石均使用真实网格；正式地图移除全部无功能房屋、废墟、墙、井、车与营帐引用，保留五座军事建筑。

环境有 73 个自然障碍碰撞体，以及由矿脉实体独占视觉与碰撞的 5 处资源导航占地。五矿周围额外 0.8 m 工作带与自然障碍没有包围盒冲突。合批装饰从此前 89,612 降至 80,552 三角面；这仅是几何规模比较，不等同于帧率测量。

```text
Godot_console.exe --headless --path . --audio-driver Dummy --script res://tests/worker_ai_test.gd
Godot_console.exe --headless --path . --audio-driver Dummy --script res://tests/construction_navigation_test.gd
Godot_console.exe --headless --path . --audio-driver Dummy --script res://tests/economy_input_test.gd
Godot_console.exe --headless --path . --script res://tests/navigation_audit.gd
python tests/model_rebuild_audit.py
```

本轮新地图实际渲染压力检查61项通过。RTX 3080 / i9-10900KF，Godot 4.6.3 Forward+ / Vulkan，1600×900、关闭VSync：100人行军136.4 FPS，160人行军86.0 FPS，初始160人混战91.8 FPS，混战P95为14.3 ms、采样平均存活146.1人。所有采样孤儿节点为0，静态内存峰值约235 MiB，退出日志无错误；记录 `artifacts/economy-stress.json`。音频以Dummy驱动真实混音；数据不代表所有设备，也不能将与旧版的差异单独归因于某一项修改。

实际画面另外记录了原有两名农民步行到矿脉与工地、采集进度、施工逐层显露直至塔完工。动态导航独立基准在29座塔变化时单次更新中位4.23ms、最大4.63ms；不改变占地时不重建。普通Delete保护完工塔，Ctrl+Delete拆塔无退款；动态废墟20秒后回收。大本营周围所有出生候选被堵住时，连续招募均不扣金币。

### Windows 0.4.0 成品验证

使用原生 Windows Desktop 预设重新导出，EXE 文件与产品版本均为 `0.4.0.0`。实际运行导出的 `AshenCrown.exe --audio-driver Dummy -- --capture`，使用默认 Forward+ / Vulkan，成功加载战场、保存画面并以退出码 0 结束；导出和发布版运行的标准错误均为空。导出日志没有警告、错误或验证脚本进入资源包的记录。

`builds/AshenCrown-Windows-x64.zip` 为 45,802,350 字节，逐项核对 ZIP 中的 EXE、PCK 和说明文档，均与导出目录 SHA-256 一致。PCK 为 11,482,080 字节，SHA-256：`64d29d1840ad75d89425f57cc97f60021f98706644a1e6018406b498fd0cbed6`。构建产物被 Git 忽略，可用 `tools/build_windows.ps1` 重建。

验证结束后以 Win32_Process 核实：本轮 Godot 无头、检查、渲染测试、发布版截图和打包辅助进程均已退出。

## 历史阶段：0.3.0 重复攻击指令与音效（2026-09-08）

以下结果与发布包记录来自上一轮交付，不作为新增农民、建造功能或新地图的验证结果。

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

该阶段另做一次 Forward+ / Vulkan、1600×900、关闭 VSync 的实际渲染压力检查，61 项通过，日志无错误，全部采样孤儿节点为 0。160 友军行军平均 87.7 FPS；初始 160 人混战平均 94.3 FPS、P95 13.8 ms，采样平均存活 147.9 人。使用 Dummy 音频驱动，游戏声音事件、声部与混音仍运行；该数据不代表所有设备的性能。记录：`artifacts/audio-stress-vulkan.json`。

Windows 0.3.0 原生发布包已重新导出；实际运行 `AshenCrown.exe` 使用默认 Vulkan，成功加载战场、保存画面并正常退出，标准错误为空。ZIP 内 PCK 与导出目录的 SHA-256 相同。原始音源目录与验证产物不进入发布包，导出日志无警告；验证辅助进程已通过 Win32_Process 核实退出。

## 此前首次交付阶段

下列检查来自音效重构前的首次交付阶段。本轮单独复跑的项目已列入上方表格，其余历史结果不代表本轮重新运行。

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

历史性能细节见 [性能记录](../tests/performance_review.md)；0.3.0 音效阶段未重复完整后端对照。窗口黑边不参与世界坐标计算；边缘移动使用完整客户区的物理像素，覆盖四条外边缘与四个角。

可重复使用的脚本保存在 `tests/`。截图、日志和大部分运行记录写入被 Git 忽略的 `artifacts/`，美术与性能数据保留其阶段说明。Windows 导出不包含测试、离线生成器或检查场景。

原生方案参考：[SubViewport](https://docs.godotengine.org/en/4.6/classes/class_subviewport.html)、[DisplayServer 客户区坐标](https://docs.godotengine.org/en/4.6/classes/class_displayserver.html)、[阴影偏移](https://docs.godotengine.org/en/4.6/tutorials/3d/lights_and_shadows.html)、[Windows 导出](https://docs.godotengine.org/en/4.6/tutorials/export/exporting_for_windows.html)。
