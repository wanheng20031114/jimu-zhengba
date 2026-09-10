# 0.12 表现包避免重复 JSON 编码

wall1 的每六名收件人约 20.329 ms 是整个 `_flush_visual` 的 inclusive wall：包含事件过滤、大小预检、primitive 校验、JSON/UTF-8、压缩及入队，不能全部归为 JSON 的 CPU 耗时。`queue_host_visual` 的 `duplicate(true)` 位于入队阶段，不在该计时范围；发送端 `slice` 是浅复制。

原正常路径先对 `batch` 做一次 JSON/UTF-8 大小预检，随后 `RelayClient.send_event` 再编码完整 envelope。本次删除正常路径预检，直接使用原有最终编码；仅当最终 envelope 超过 32 KiB、在原生发送之前返回 `ERR_OUT_OF_MEMORY` 时，才缩小批次并重试。成功包只编码一次。超过上限的单事件仍移除并报错，`ERR_BUSY`、原生失败不拆分或消费等待队列，primitive 验证及线协议均保留。

该错误分支不会把一次已经原生入队的包误认成超大后再次发送：官方 [Godot 4.6.3 ENetPacketPeer::_send](https://github.com/godotengine/godot/blob/4.6.3-stable/modules/enet/enet_packet_peer.cpp#L182) 将底层发送结果映射为 `OK` 或 `FAILED`；本链 `ERR_OUT_OF_MEMORY` 来自 RelayClient 发送前的 decoded-size 检查。

全新真实编码/队列窄回归 **20/20 通过**，仅替换最底层发送为捕获器，不做网络投递或 FPS 声明：

- 正常 96 条表现，decoded 13,731 字节、encoded 392 字节，只调用一次编码，完整包与同一原始 envelope 的期望字节一致。
- 超大合法批次按 96、48、24、12 缩小，只提交最后一个合法包（decoded 18,003 字节）；尾部事件顺序保留。
- 单事件超大、50 ms 限制、每帧预算不足、下一帧原样重试、原生 `FAILED`、非法 primitive 和过期事件均符合预期。

没有移除事件深复制，也没有引入新的受信 JSON 入口。已移除的重复工作可以从调用链确定，但本次没有测定独立耗时收益；后续应以真正发行运行时测量。测试为官方 Godot 4.7.2 Windows headless / BelowNormal，stderr 为零，辅助进程已退出并通过 CIM 复核。全新临时夹具与结果保留在根工作区 `.local/release-0.12-visual-encode-tests/`，源码及证据哈希见同名 JSON。
