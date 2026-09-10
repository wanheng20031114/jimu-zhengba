# 0.12：原生 UDP 接收缓冲的有界复现

时间：北京时间 2026-09-11 00:08（UTC 2026-09-10 16:08）。对应[紧凑结果与真实哈希](release-0.12-udp-buffer.json)。

**确认存在 64 KiB 用户态接收缓冲丢尾包的机制：相同六份 12,000 字节数据，累积时只能消费前五份，及时消费时六份全部取回。原生 ENet＋DTLS 同批发送与间隔发送也分别得到 5/6 与 6/6。** 这给分散发送提供了依据，但没有证明它是公网所有丢包或房主卡顿的唯一原因。

## 方法与实测

使用官方 Windows Godot **4.7.2 `ed1daf0bf`**，一个无头进程内的独立原生网络端点，仅 localhost、临时证书。没有加载游戏、改生产文件、连接公网、修改内核参数或重启中继。总共 58 项 API／原始 UDP 断言通过，最终标准错误为空。

原始 UDP 对照用 `UDPServer` 与 `PacketPeerUDP`。每发出一份 12,000 B 数据，都先让 `UDPServer.poll()` 排空内核 socket，等待 5 ms，以区分用户态缓冲蓄积和内核接收队列溢出；区别只在是否读取已收到的数据。六包总应用载荷均为 **72,000 B**。

| 原生路径 | 消费／发送安排 | 收到的数据编号 | 结果 |
|---|---|---|---:|
| UDPServer | 每包 poll，但最后才消费 peer | 0、1、2、3、4 | 5/6 |
| UDPServer | 每包 poll 后立即消费 | 0、1、2、3、4、5 | 6/6 |
| ENet＋DTLS | 六个频道同批入队并 flush | 0、1、2、3、4 | 5/6 |
| ENet＋DTLS | 每份发送后服务两端 20 ms | 0、1、2、3、4、5 | 6/6 |
| ENet 裸 UDP | 六个频道同批入队并 flush | 0、1、2、3、4 | 5/6 |
| ENet 裸 UDP | 每份发送后服务两端 20 ms | 0、1、2、3、4、5 | 6/6 |

原始 UDP 累积组的队列数依次为 **[1, 2, 3, 4, 5, 5]**，消费组为 **[1, 1, 1, 1, 1, 1]**。原生 ENet 测试的发送前、后 throttle 均为 **32**（满值），因此这两组 DTLS 对照没有把原生拥塞限速误算成缓冲溢出。

裸 ENet 同批也发生丢包，因此不能把它的丢包归于 DTLS 专用环形缓冲；Windows 内核缓冲等路径可能参与。**独立逐包清空内核、只蓄积 UDPServer peer 的对照**才是用户态缓冲因果证据。每个变体只做了一次小机制样本，数据不代表丢包概率、游戏 FPS 或公网稳定吞吐。

首轮夹具把 DTLS 握手等待固定为 120 ms，等待不足后误用空 peer，中止于测试脚本；已改成有上限地等待真实 CONNECTED 再开始发包。首轮日志与源码哈希保留，未归为生产闪退。

## 对应的官方原生实现

`PacketPeerUDP` 构造时将环形缓冲设为 `resize(16)`，即分配 2¹⁶ 字节，实际可用空间还保留一个区分空满的字节。每个 UDP 数据报另外写入 24 B 地址／长度信息；空间不足时 `store_packet` 返回错误。共享 socket 连接没有扩大这个环形缓冲。[PacketPeerUDP 实现](https://github.com/godotengine/godot/blob/4.7.2-stable/core/io/packet_peer_udp.cpp#L305)、[构造](https://github.com/godotengine/godot/blob/4.7.2-stable/core/io/packet_peer_udp.cpp#L354)、[RingBuffer 实现](https://github.com/godotengine/godot/blob/4.7.2-stable/core/templates/ring_buffer.h#L186)

`UDPServer.poll()` 一次循环排空 socket，将数据送入对应 peer，未处理 `store_packet` 的错误返回。所以数据可以已经离开内核、却在这层用户态缓冲被丢弃，不增加 Linux socket drop 或中继应用 reject。[UDPServer 官方源码](https://github.com/godotengine/godot/blob/4.7.2-stable/core/io/udp_server.cpp#L44)

官方 `PacketPeerUDP.bind(..., recv_buf_size)` 可设置自己绑定的 UDP peer 缓冲；但 ENetConnection 没有暴露内部 DTLS peer 或接收缓冲 setter，UDPServer 的 `listen` 也没有该参数。现有 ENet＋DTLS 封装不能直接用这个接口扩内部共享 peer 缓冲。[PacketPeerUDP API](https://docs.godotengine.org/en/4.6/classes/class_packetpeerudp.html)、[ENetConnection API](https://docs.godotengine.org/en/4.6/classes/class_enetconnection.html)、[UDPServer API](https://docs.godotengine.org/en/4.6/classes/class_udpserver.html)

此外，Godot 自带 ENet socket 适配层对 RCVBUF／SNDBUF 设置返回不支持；不能假定普通 ENet 初始化请求的缓冲大小已成功应用。改 sysctl 不会扩大上述用户态环形缓冲。[Godot ENet socket 适配](https://github.com/godotengine/godot/blob/4.7.2-stable/thirdparty/enet/enet_godot.cpp#L129)

## 修复方向与尚未证实部分

优先在现有协议内做有界、轮转的最新状态发送：每个显示帧最多安排 **2 个收件者**，快照与表现的实际应用突发预算合计**严格低于 48 KiB**，给 DTLS、ENet 分片和可靠控制留空间；控制消息优先，旧的未发送快照被新状态替换，不按补跑的物理 tick 追发历史。限制必须放在真正入队／flush 的共同出口附近，否则同帧多条发送路径仍可能合成大突发。

48 KiB 是候选应用预算，不是对任何重传积压或 MTU 都成立的安全证明。个别帧若本身超过预算，应通过减少冗余状态或独立验证的有界分块处理，不能截断状态，也不能为共享压缩而向玩家广播其他人的私有内容。将各收件人的完整快照再套成一份大 envelope 会增加单包重组和隐私路由验证负担，本轮不优先引入新消息格式。

另一个源码疑点是 ENet 在限速丢弃分片组时只比较两种序号，没有比较频道，可能连带删除后续同序号频道。此次通过延迟 ACK 尝试诱导限速未成功，native throttle 一直为 32，六频道各 96 个小包全部到达；**跨频道连带丢包尚未原生复现，不能作为已确认根因**。

本测试是 4.7.2 单进程机制验证。实际 **4.6.3 房主＋4.7.2 中继**的公网证据目前仍是：应用发送数公平，接收端后两席位明显更少，内核丢包增量为零；还需用同一真实七人 500 单位场景验证分散发送后的完整交付、各席位空窗和房主墙钟成本。不能用本地 6/6 替代该验收。

最终辅助进程已正常退出，并按临时目录匹配命令核实无残留；首轮中止进程也已退出。新夹具、日志、紧凑数据留在 `.local/release-0.12-buffer-tests`，供主任务统一归档／清理。
