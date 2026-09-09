# 积木争霸 · 实施约定

Godot 4.6.3 原生 3D RTS。暖砂岩、蓝金屋顶与部队服饰，45° 正交战场；当前版本 0.9.0、协议 8。完整规则见 README 与 `report/balance-0.8.2.md`，不要从旧报告或历史生成器恢复过时数值。

## 代码与数据边界

- `scripts/session.gd` 负责持久连接、对局配置、场景切换和脱敏生命周期记录；`scenes/lobby.tscn` 是启动场景，`scenes/main.tscn` 是战场。
- `data/units`、`data/buildings`、`data/upgrades`、`data/maps` 是可编辑 Resource；HUD、图鉴、AI、经济与伤害结算读取 `BalanceCatalog`。
- `PlayerState.owner_id` 是完整席位数组的稳定索引，`alliance_id` 独立。空位用 `controller="open"`，通过 `is_participating()` 排除资产、经济、Bot、视野、胜负和接管。不要压缩玩家数组。
- `NetworkProtocol.MODES` 是模式、队伍容量与地图的唯一映射；`match_config_error` 与 `room_start_error` 供房主、客户端与中继复用。4v4 允许两队各 1～4 人，乱战允许 2～8 人，至少两个实际阵营。
- `scripts/game.gd` 运行 30 TPS 权威模拟，`MatchCommands` 验证序号、所属玩家、金币与人口。客户端发送意图，不运行经济、伤害或 Bot。
- `MatchReplication` 按每名玩家视野生成 15 Hz 快照，七个远端收件人交错到两步发送。客户端用 120 ms 时间线插值，失去视野的敌军与建筑立即移除，不留下模型记忆。
- 攻击出手记录攻击力及类别附伤，命中时读取目标当前护甲。追击使用实际位移速度估计和径向释放范围，近战前摇可追步，完整冷却与动画关键帧保持。

## 原生场景与表现

单位根节点为 CharacterBody3D，建筑为 StaticBody3D；模型是独立可编辑 PackedScene。节点结构优先保存于 `.tscn`，运行时实例化整套已有场景，不逐件构造模型或界面。

模型动画使用 AnimationPlayer；物理使用 NavigationAgent3D/Jolt 与原生物理插值。静态地图保留 NavigationMesh，动态施工占地由 ConstructionNavigation 管理。PathBudget 对路径查询按逻辑步限额。

地图构建脚本为 `tools/build_skirmish_maps.py`；六张独立地图在 `data/maps/` 与 `scenes/maps/`。4v4 为 192×184，八人乱战为 192×192，每席具有出生矿、扩张矿与左侧免费防御塔。占地、道路、出生点与矿槽验证是重建的一部分。

大厅与图鉴以原生 Control/Container、SubViewport 和游戏模型组成。图鉴显示时只运行当前模型，关闭时停用预览。设置使用本地 ConfigFile；更名迁移仅复制旧版两份偏好文件，已有新版配置优先。

阵营色通过共享材质和实例参数应用：自己蓝色、盟友黄色、敌方红色。CombatLayers 为八个阵营分配独立单位及建筑层，新增模式必须检查全部阵营组合。

## 构建与联机

修改规则或地图后运行 `python tools/build_content_manifest.py`，再使用 `tools/build_windows.ps1 -VersionedOutput 0.9.0` 导出。发布程序为 `积木争霸.exe` 和同目录 PCK，ZIP 仅包含五项明确交付文件；测试和本机密钥均不进入包。

中继专用服务为 `jimu-zhengba-relay.service`，端口 UDP 24571，原生 DTLS 验证固定受信身份。服务器使用隔离且校验 SHA256 的 Godot 4.7.2 运行时。详见 `server/README.md`。更名时旧服务名仅用于迁移；不可更改其他服务或其端口。

按修改范围运行有效回归，先完成可运行包，再做重负载验证。性能报告须说明实测人数、场景、帧 P95/P99、30 TPS 实际达成情况和共享机器条件，不能把目标当作实测帧率。

每个完整阶段中文 commit + push。源码、场景、配置和文档采用 UTF-8；供 Windows PowerShell 5.1 执行的中文脚本使用 UTF-8 BOM。结束前关闭并命令核实自己启动的辅助进程，保留用户编辑器与正在运行的游戏。
