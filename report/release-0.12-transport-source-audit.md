# 0.12 原生传输、发布时序与导出归一化审查

本记录是只读源码、既有日志及发行文件检查。没有启动引擎、修改传输参数、抓取玩家流量或重启中继。它不替代七客户端压力测试，也不把后续版本修复后的表现归给旧包。

## EVENT_ERROR 的范围与已排除的误解

Godot 4.6.3 `ENetConnection.service()` 将原生 `enet_host_service()` 的负返回值合并为 `EVENT_ERROR`；接收/断开事件找不到对应 `ENetPacketPeer` 时也会返回相同枚举。因此 `native_error` 本身没有给出 Winsock、TLS 或 ENet 超时的唯一原因。[原生入口](https://github.com/godotengine/godot/blob/4.6.3-stable/modules/enet/enet_connection.cpp)

- 普通非阻塞 UDP `ERR_BUSY` 被 ENet socket 包装层转成零字节，没有直接转成致命事件。超过 ENet 接收缓冲的包有单独丢弃分支；不能仅凭快照大于 MTU 就断言连接必定失败。[Godot ENet socket](https://github.com/godotengine/godot/blob/4.6.3-stable/thirdparty/enet/enet_godot.cpp)
- Windows `WSAENOBUFS` / `WSAEMSGSIZE` 可沿 UDP → DTLS 的失败路径成为错误，但正常路径应有 SSL 错误或发送失败输出。当前 host 日志没有这些文本，故这只是待验证可能性。普通 `WSAEWOULDBLOCK` 与这两种错误不同。[Winsock 映射](https://github.com/godotengine/godot/blob/4.6.3-stable/drivers/windows/net_socket_winsock.cpp)、[UDP 包装](https://github.com/godotengine/godot/blob/4.6.3-stable/core/io/packet_peer_udp.cpp)
- `print_mbedtls_error()` 使用 C `printf` / `fflush(stdout)`；排查需包含 stdout，不能只看 Godot 日志或 stderr。[TLS 日志实现](https://github.com/godotengine/godot/blob/4.6.3-stable/modules/mbedtls/tls_context_mbedtls.cpp)
- 快照实际采用 `FLAG_UNRELIABLE_FRAGMENT`，没有证据表明本次大快照意外全部变成可靠分片。原生 MTU、UDP 数据报数与应用快照包数不是同一指标。

存在一条与“客户端无 SSL 错误文本”相容的路径：收到 TLS `PEER_CLOSE_NOTIFY` 时，`PacketPeerMbedDTLS.poll()` 会静默断开；随后 ENet DTLS socket 发现状态不再 CONNECTED，返回失败。这说明没有错误文本不能排除对端主动关闭 TLS。[DTLS 状态转换](https://github.com/godotengine/godot/blob/4.6.3-stable/modules/mbedtls/packet_peer_mbed_dtls.cpp)

只读比较官方 4.6.3 与 4.7.2：ENet 原协议/peer 文件相同，`service()` 的致命映射和 DTLS 读写主要错误处理没有本次问题的明确修复。4.7.2 新增 ENet peer 与 DTLS session 生命周期绑定；服务器处理 peer 断开时清理对应 DTLS session，可产生上述 close-notify 路径。不能由此宣称换客户端引擎必然解决。[4.7.2 peer 生命周期](https://github.com/godotengine/godot/blob/4.7.2-stable/modules/enet/enet_packet_peer.cpp)、[4.7.2 DTLS socket](https://github.com/godotengine/godot/blob/4.7.2-stable/thirdparty/enet/enet_godot.cpp)

## 既有压力日志的含义

`stress1` host 首次在进程时间 30.431 秒记录 `native_error`，最近应用收包仅 509 ms 前；重连后 35.009 秒再次出错，收包间隔 467 ms。这不支持把首个错误解释为产品的 8 秒无收包判断。15.805 秒的 host health 为 2 FPS、逻辑 tick 243，说明该七进程同机测试已出现严重 CPU 压力，不能据其 FPS 声称单客户端渲染表现。

两端产品都显式使用 `set_timeout(8, 2000, 5000)`，原生最长重传等待为 5000 ms。首次错误发生在进程第 30 秒，不等价于“触发默认 30 秒 ENet 超时”；应回看错误前的可靠命令和 ACK，而不是仅看进程启动时间。

服务器记录中，第一次 `transport_disconnect` 在 15:33:36.210361 UTC，DTLS `-30464` 在 36.343756，晚 133 ms；第二次断开之后也才出现该 TLS 码。`-30464` 是 `-0x7700`，即 unexpected-message，并不是已证明的最初断开原因。服务未重启、没有应用层拒绝；系统接收丢弃计数当时只有累计值，没有测试前基线，不能直接把其全部归给该测试。[SSL 错误定义](https://github.com/godotengine/godot/blob/4.6.3-stable/thirdparty/mbedtls/include/mbedtls/ssl.h)

下一次对照应记录每个实际连接的当前/历史 RTT 与方差、packet throttle/limit/epoch、实际 throttle 配置、loss 原值，结合已有累计 native 收发数、有效快照 sequence、gap，以及服务器 UDP 丢弃增量。`get_statistic()` 是只读字段采样；`host_pop_statistic()` 则会取走计数，不能让两个观察者分别 pop 后假装是完整值。[统计 API 实现](https://github.com/godotengine/godot/blob/4.6.3-stable/modules/enet/enet_packet_peer.cpp)

特别核实：`throttle_configure(500, 4, 1)` 除了设置本地参数，还发送可靠配置命令；对端收到后也更新自己的参数。因此“客户端没有显式调用”不等价于“客户端始终使用默认 5000 ms”。应读实际 statistic，避免盲目关闭拥塞控制。ENet throttle 可以抑制不可靠快照，本身并不直接生成 `EVENT_ERROR`。[配置发送](https://github.com/godotengine/godot/blob/4.6.3-stable/thirdparty/enet/peer.c)、[配置接收和原生超时](https://github.com/godotengine/godot/blob/4.6.3-stable/thirdparty/enet/protocol.c)

## latest-state 发布候选的静态复核

检查范围为基于 `6409bb3` 的待提交 `Game._process → MatchReplication.publish_latest → RelayClient.flush_outbound` 改动，具体文件摘要见 JSON。此项是源码审查，不是运行通过声明。

- 权威移动、经济、攻击时钟仍在原生 30 TPS；只把快照发布移到每帧 physics 完成之后。Godot 主循环先执行全部 physics、物理 Timer、导航回调，再进入 idle/process，采样时不处于半个单位更新循环中。[主循环](https://github.com/godotengine/godot/blob/4.6.3-stable/main/main.cpp)、[SceneTree 顺序](https://github.com/godotengine/godot/blob/4.6.3-stable/scene/main/scene_tree.cpp)
- 66667 μs 整数 deadline 跳过过期时刻，不循环补发历史快照；未产生新 tick 时不重复构建。暂停、重连非 match 状态和 finished 均不发布；恢复后的新逻辑步再发送。
- 视觉事件仍用权威 elapsed 标记并依客户端播放时钟展示，最终击杀仍在可靠结算包里，与最后不可靠快照独立。`flush()` 只发送队列，不在这个调用里派发收到的应用事件。
- 需要运行数据确认：六/七接收者现在同批发送，单批瞬时数据量增加；低 FPS 的有效发布率最多等于实际帧率，不能承诺固定 15 Hz。deadline 抖动造成相邻发送小于 50 ms 时，原有 per-recipient BUSY 限制会跳过一次，应看实际 sequence 与接收 gap。

静态审查未发现必须阻止该候选测试的时序错误，也没有据此确认传输故障已经修复。

## 9399206 发行候选的文件和音频检查

该旧候选已被后续编码/发布修复取代；这里只记录其检查边界。五项交付文件的 size/SHA256、ZIP 摘要以及 ZIP 内五文件与外部文件逐字一致。PCK 原生 v3 目录共 835 项，包含六种 batched 模型；未发现 skinned、tests、tools、server、`.local`、private 或 `.env` 路径。正式场景开启批量显示、静止避让退出、路径元数据省略和 map-iteration 缓存；共享流场、静态扫掠快路、蒙皮候选关闭。

`default_bus_layout.tres` 导出前后变化仅包括 UID、字段顺序、默认属性的省略/显式写回。有效音频语义一致：Master −1.411621 dB，limiter ceiling −1 dB、release 0.12；UI/Combat 0 dB、Foley −2 dB，均送 Master；Combat compressor threshold −16、ratio 2.5、attack 2000 μs、release 160 ms、mix 0.7。省略的 limiter pre-gain 和 compressor gain 默认均为 0，mute/solo/bypass 默认 false，初始 bus 0 默认名 Master。[Limiter 默认值](https://github.com/godotengine/godot/blob/4.6.3-stable/servers/audio/effects/audio_effect_hard_limiter.h)、[Compressor 默认值](https://github.com/godotengine/godot/blob/4.6.3-stable/servers/audio/effects/audio_effect_compressor.cpp)、[音频总线默认值](https://github.com/godotengine/godot/blob/4.6.3-stable/servers/audio/audio_server.h)、[Master 初始化](https://github.com/godotengine/godot/blob/4.6.3-stable/servers/audio/audio_server.cpp)

主工作区整合只读检查：`c67d54d` 是候选祖先，可以快进；当前 dirty 文件仍需先备份并处理重叠，不能直接 stash/pop 整块旧导航实验。九个未跟踪导航覆盖文件中八个与正式候选逐字等同（换行归一化），一个只有两行注释差异。用户 project/audio 设置应保留；export 需合并选项并保留新版版本号和候选资源排除规则。此次没有执行 restore、merge、删除或移动。
