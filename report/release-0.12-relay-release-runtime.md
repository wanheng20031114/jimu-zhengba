# 0.12 中继使用正式导出模板

只读核查确认当前公网中继实际运行 **官方 Godot 4.7.2 编辑器二进制**，通过 `--headless --script` 启动。运行中 `/proc/<pid>/exe` SHA256 与经过官方归档校验的本地编辑器完全一致，版本为 `4.7.2.stable.official.ed1daf0bf`；检查前后服务 PID、Invocation 和零重启状态相同，未修改远端文件或配置。

官方 [SConstruct](https://github.com/godotengine/godot/blob/4.7.2-stable/SConstruct#L492) 对 editor/template_debug 启用 `DEBUG_ENABLED`；headless 只选择显示模式，不改变编译标志。[专用服务器文档](https://docs.godotengine.org/en/4.6/tutorials/export/exporting_for_dedicated_servers.html) 推荐使用更精简的导出模板。因此准备同版本正式模板，保留完整协议和数据验证，单独验证运行时差异；本报告尚不声称实际 CPU 或投递率已经改善。

## 构建与启动

- 新增原生 `relay_bootstrap.tscn`，包含原 RelayServer 子场景；其 Node 脚本独占配置及启动逻辑，开发版 SceneTree 入口仅复用该场景。RelayServer 本身继续在退出时停止原生连接。
- `build_relay_release.py` 只打包服务器必需的八份源码/配置。官方编辑器导出 PCK，原始 release 模板按同名复制；二进制不经过自定义引擎构建或补丁。
- 完整官方 `Godot_v4.7.2-stable_export_templates.tpz` 共 1,281,349,702 字节，SHA256 `f298490b8d44d934be425a5a65a51bf15f422428b229a06a6e11d9ffea248011` 校验通过，再抽取 Linux/Windows release 模板，并在构建工具固定两个目标二进制的 SHA256。
- Linux 和 Windows 导出 PCK 完全相同，均为 51,020 字节，SHA256 `f4e86bc90b5b202593c5951c116a7b0a98bc7d077ec3f116f87cc6e57c77406d`。构建收据包含全部源码和包体哈希。

正式启动依靠二进制旁的同名 PCK，不能继续用被 release 模板禁用的 `--script`、`--path` 或 `--main-pack` 覆盖。部署需将 `jimu-relay` 与 `jimu-relay.pck` 放在同一不可变版本目录，只传 `--headless`；配置与信任身份通过原环境变量/外部文件提供，私钥不会进入 PCK。旧版本目录和原单元须保留到新服务就绪，以支持完整回退。

## 本机原生验证

三个原生导入/导出助手均正常退出、stderr 为零。随后用真正的 **Windows 4.7.2 release 模板** 启动同一个 PCK，实测日志 `editor=false debug=false dedicated_server=true`，8 房 / 每房 8 人 / 协议10正常就绪。

独立客户端通过回环地址与临时自签证书完成原生 ENet/DTLS、协议/内容清单 hello 校验、创建房间和离开。两端均 exit0、stderr0；服务器用有界帧数正常结束。此检查没有访问公网、没有采用生产私钥，也没有关闭 TLS 校验。首轮夹具将带空格的版本字符串误判为无运行时标志；保留首轮结果，修正夹具正则后同一原封不动 PCK 通过。

Linux 模板已验证官方来源和二进制哈希，但本阶段尚未在 Linux 主机执行新 PCK，因此不将 Windows 回环检查称作 Linux 或公网验收。所有本轮导出、下载和回环验证助手均已退出并通过 CIM 复核；用户编辑器及线上服务保留。

临时证据在根工作区 `.local/release-0.12-relay-runtime-tests/`，已验证模板依赖在 `.local/network/runtime/templates-4.7.2/`。本阶段未删除临时目录；部署前如服务器或协议源码变化，必须重新构建并核对收据，不能混用旧 PCK。
