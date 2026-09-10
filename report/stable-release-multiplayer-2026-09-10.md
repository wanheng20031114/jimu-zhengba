# 积木争霸：稳定发行版与上海中继对齐记录

日期：2026-09-10。此次交付让 `builds/windows` 中的最新稳定发行包可以联机；正在开发的共享流场、静态移动网格等实验代码没有打包或部署。极端 896 单位性能问题仍在独立优化，本记录不表示它已经解决。

## 应当使用的版本

| 项目 | 本次值 |
|---|---|
| 本地启动程序 | `builds/windows/积木争霸.exe` |
| 本地完整下载包 | `builds/积木争霸-Windows-x64.zip` |
| 游戏版本 / 网络协议 | `0.11.0` / `10` |
| 稳定源码快照 | `dc32f9ca3d7a50117e9f435bb47cc5eb895fbea8` |
| 发布标识 | `v0.11.0-protocol10` |
| ZIP 大小 | 69,117,902 字节 |
| ZIP SHA256 | `dc0d12c32fa671ebdf9d54ed9fa4b4a722b56c665e35ec539747f335eb8988b6` |
| 内容清单 SHA256 | `b78f1a5c73687b3ccdfe34f2f5a5a409f172235641322c9d02eb5376a3d14c7b` |

ZIP 内的 EXE、PCK 已逐字节比对，和 `builds/windows` 中的文件一致。所有联机玩家应使用这一份发行包。旧目录 `builds/windows-0.11.0` 虽然游戏版本同为 `0.11.0`，实际协议为 9，不能连接此次更新后的服务器。

公开发布页：[积木争霸 0.11.0 联机更新（协议 10）](https://github.com/wanheng20031114/jimu-zhengba/releases/tag/v0.11.0-protocol10)。附件名称包含 `protocol10`，避免与旧包混淆。曾临时创建但没有成功上传附件的协议 9 发布页及其 tag 已撤回；现有本地旧版本目录保留。

直接下载：[Windows x64 联机更新 ZIP](https://github.com/wanheng20031114/jimu-zhengba/releases/download/v0.11.0-protocol10/jimu-zhengba-0.11.0-protocol10-Windows-x64.zip)。GitHub 返回的附件大小为 69,117,902 字节，SHA256 与本地 ZIP 完全一致，远端 tag 已通过 `git ls-remote` 核实指向上述稳定提交。首次经过系统代理的大文件上传写入超时且未生成附件；之后仅此上传请求改为直连并流式传输，约 165 秒成功，未改变用户的全局代理配置。

## 原因和实际部署

问题是客户端已经使用协议 10 和新的内容清单，但上海中继仍在运行协议 9。仅凭游戏标题中的 `0.11.0` 无法区分这两份包，握手会拒绝不匹配的客户端。

部署使用预先冻结的稳定源码 ZIP，从中只取中继项目、`relay_main.gd`、`relay_server.gd`、`network_protocol.gd`、中继场景、公共证书和内容清单，并使用同一快照的部署工具；该清单与最新正式 PCK 自报的清单完全相同。没有在当前实验工作树中重新生成清单，也没有重新导出客户端。私钥复用现有本地受保护文件，不放入稳定源码目录、公开仓库或发行 ZIP。服务器继续使用现有已校验的 Godot `4.7.2-stable` 中继运行时，Windows 游戏仍使用其原发行模板。

| 项目 | 更新前 | 更新后 |
|---|---|---|
| 服务 | `jimu-zhengba-relay.service` | 同一独立服务 |
| 中继发布目录 ID | `05350c9edc56bb64` | `cf99f96528ccb274` |
| 协议 | 9 | 10 |
| 清单 SHA256 | `46515ad0304939e2eef382c62d04382be2f300605834d39e0aba082c2d9d6377` | `b78f1a5c73687b3ccdfe34f2f5a5a409f172235641322c9d02eb5376a3d14c7b` |
| MainPID | 284254 | 284742 |
| NRestarts | 0 | 0 |
| 服务状态 | active/running | active/running |
| 无关 UDP 24570 服务 PID | 270544 | 270544，未变化 |

更新后的独立服务使用 UDP 24571。已读取当前 invocation 的 readiness 日志：`protocol=10 rooms=1 humans=8`，无 `SCRIPT ERROR`。其中 `rooms=1` 表示容量是一间房，不能解释成当前有一间房正在游戏。现有中继没有管理用的实时房间查询接口，部署前无法通过日志确认占用人数；这次按用户明确要求更新服务，发生了短暂服务重启。没有修改原 UDP 24570 服务或安全组。

## 正式发行包验证

对本地实际发行 EXE 执行现有 `tests/network_release_runner.py`，没有用实验源码运行客户端：

```powershell
python tests/network_release_runner.py 'builds/windows/积木争霸.exe' --catalogue-only
python tests/network_release_runner.py 'builds/windows/积木争霸.exe' --room-mode 4v4 --empty-slots 5,6
```

| 验证 | 结果 |
|---|---|
| 导出模板、目录与数值检查 | 177/177 通过；95 个目录资源、75 个资源数值检查 |
| 对当前上海服务实际联网 smoke | 191/191 通过 |
| 实际 build / protocol / content_hash | `0.11.0` / `10` / `b78f1a…` |
| 原生 DTLS 握手 | 成功，546 ms |
| 房间 | 4v4，保留 5、6 两个空位 |
| 创建、开局、结束及房间释放 | 通过 |
| failures / error_codes | 均为空 |
| 标准错误输出 | 空 |

这验证发行包能完成真实加密握手和房间生命周期，不等同于重新验证一整场人工多人对战，也没有据此宣称网络压测或 896 单位性能达标。

### 随后收到的持续对局故障

用户随后反馈约 20 秒后显示连接中断。17:34 的只读服务器核查显示同一 PID 284742、同一 invocation、NRestarts 0，服务 active/running，内存约 37.8 MB；当前 invocation 无 ERROR/WARNING，最近 20 分钟的内核日志没有 OOM 记录。没有通过重启掩盖现场。这些结果只能排除已观察到的服务崩溃、重启或 OOM，不能证明连接链路或客户端持续对局正常；持续断线原因仍在另行诊断。现有服务不记录实时 peer/房间占用，`rooms=1` 仍只表示容量。

验证后已用 Windows 进程查询核实：仅保留用户原有 Godot 编辑器 PID 33896，没有本次验证遗留的 headless/check-only Godot 或游戏进程。用户随后正常启动的发行版属于游玩进程，保持运行；不再创建测试房间或重启中继，避免占用唯一房间。
