# 设置与主菜单

主菜单保留真实 3D 城镇，提供 1v1 / 2v2 单人开局、多人房间、设置、退出游戏。多人面板的“返回主菜单”会离开房间并取消尚未完成的连接；退出会主动断开网络。对局中的暂停、返回及退出入口由战场菜单提供。

设置作为 `Session/Settings` 原生 CanvasLayer 长驻，并在暂停状态下正常工作；打开设置自身不暂停比赛，也不改变联网房主暂停状态。

## 可调整项目

- 显示：窗口、无边框全屏、独占全屏；当前尺寸及 1280×720、1600×900、1920×1080、2560×1440；垂直同步；30 / 60 / 90 / 120 / 144 / 165 / 240 FPS 或不限帧数。
- 全屏窗口按显示器尺寸展示，所选分辨率控制原生 3D 渲染比例；窗口模式直接改变窗口尺寸。UI 随视口适配。
- 声音：主音效音量、静音；不播放背景音乐。
- 镜头：平移速度倍率、滚轮缩放倍率、鼠标边缘移动开关。
- 热键：34 个原生 InputMap 动作，涵盖战斗、训练、选中、编队、暂停、界面和镜头方向。F2 / G、F5 / P、B / Home 保留初始别名。重新绑定动作会替换其旧别名；Ctrl / Shift 保留给组合指令，Esc 与 F12 不允许占用。

界面先编辑草稿，点击“应用”或“完成”后生效并使用 ConfigFile 保存到 `user://settings.cfg`。“取消”、关闭或 Esc 会丢弃未应用草稿；捕获新按键期间 Esc 只取消本次捕获。重复按键明确显示冲突操作。

显示模式或分辨率改变后，出现 15 秒保留确认。超时或取消会恢复先前设置和窗口位置；计时忽略游戏时间缩放，暂停中仍有效。尚未确认的显示配置不会写入用户配置文件。

## 接口

`/root/Session/Settings` 使用 `GameSettings`，提供 `open_menu()`、`close_menu()`、`is_open()`、`resolve_key(event)`、`hotkey_text(action)`、`key_label(canonical_key)` 和无参数 `changed` 信号。镜头读取 `edge_scroll_enabled`、`camera_speed`、`zoom_speed`；声音读取 `volume_percent`、`muted`，或调用 `set_volume_percent()`、`set_muted()`。

`resolve_key()` 根据当前物理按键绑定返回原有规范键，并保持原事件 Ctrl / Shift 状态。InputMap 同时供镜头方向持续按键使用。主菜单不再强制覆盖为 60 FPS，统一尊重帧数设置。

## 验证

`tests/settings_test.gd` 共 132 项通过：原生动作及别名、Ctrl / Shift、重绑冲突、保留按键、草稿与取消、音频混音器、FPS、ConfigFile 跨实例重载、暂停中显示超时、确认及无效配置保护。

`tests/settings_visual_test.gd` 在 Vulkan 下渲染主菜单、四个设置分类及显示确认弹层；实际窗口从 1600×900 调整至 1280×720，再恢复原尺寸。测试配置路径位于 `.local`，不覆盖玩家偏好。验证进程均退出后单独查询 Godot 进程核实。

原生能力：[InputMap](https://docs.godotengine.org/en/4.6/classes/class_inputmap.html)、[DisplayServer](https://docs.godotengine.org/en/4.6/classes/class_displayserver.html)、[ConfigFile](https://docs.godotengine.org/en/4.6/classes/class_configfile.html)。
