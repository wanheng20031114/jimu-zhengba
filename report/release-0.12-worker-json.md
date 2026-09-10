# 0.12 单批后台 JSON 编码与生命周期验证

真实发行模板的七端、500 单位诊断中，房主每批快照 JSON 编码约占主线程 17.8 ms。本候选将这段纯数据编码交给原生 `WorkerThreadPool`，并继续在主线程采样单位、动画、视野和经济。它不改变网络协议、JSON 字段、数值、权威 30 TPS 或伤害结算。本节记录正确性验证，尚不证明七端性能改善或 60 FPS。

`SnapshotJsonBatchJob` 是一次性 `RefCounted`。每个对局最多持有一个待完成任务；任务忙时不再构建或排队新快照，原有待发 JSON 仍按每帧字节额度和收件人轮转发送。主线程只在 `is_task_completed()` 为真后调用 `wait_for_task_completion()`，取得结果并释放原生任务资源。worker 同时释放输入容器，避免把这部分析构留到主线程。任务输出保留采样时的 tick/time。

暂停、重连和结束使发布 epoch 失效，迟到的编码结果只被回收，不再发出。普通失效不等待正在编码的任务；reset 和节点退出必须 join，防止原生任务遗留。任务量有界并不意味着任意硬件上都有固定 30 ms 完成上限，实际编码、线程池等待和下一帧发现结果的延迟仍需测量。官方要求每个原生任务最终 wait，且活动场景树不能由工作线程访问。[WorkerThreadPool](https://docs.godotengine.org/en/4.6/classes/class_workerthreadpool.html)、[线程安全接口](https://docs.godotengine.org/en/4.6/tutorials/performance/thread_safe_apis.html)

输入所有权由现有 builder 保证：玩家公开数据和坐标都是新值；研究映射复制后只有建筑 ID；生产和研究队列做深复制；指令计划生成全新 primitive 点位；迷雾输出 base64 字符串与新数组。公共实体字典只在本批收件者之间共享，私有队列、金币、计划不会进入公共缓存。移交后主线程不再访问输入，因此产品不额外逐批 deep-copy 或递归扫描。JSON 的原生实现对调用内字符串和递归标记集合操作；这里不传入会触发对象转换的 Node、Resource 或 Callable。[Godot 4.6.3 JSON 源码](https://github.com/godotengine/godot/blob/4.6.3-stable/core/io/json.cpp)

全新小型回归加载实际生产 `main.tscn`、2v2 四玩家及原生线程池，完成 **1,938 项断言，0 失败、0 脚本错误**。这个数量包括逐字段 primitive 检查。测试先记录预期 JSON，再把独占输入交给由 Semaphore 暂挡的真实 worker；随后修改玩家金币/名字/研究、建筑队列/集结点、单位位置/生命/未来指令、迷雾，并杀死单位。最后放行 worker，四份 JSON 与变更前逐字节相同，后续新快照则能观察到变更与死亡。

同一夹具还覆盖单任务重复提交拒绝、忙时发布不等待、暂停/重连/结束丢弃旧 epoch、恢复后新状态进入三收件者轮转，以及 reset/exit 回收任务。传输端为捕获器，**不是公网、持续联机或渲染性能测试**。Godot 4.6.3 官方编辑器运行时用于这次功能检查；后续 FPS 必须使用真实 release template。配套 JSON 保存源码和夹具摘要、断言结果及退出记录。增量导入进程 36208、验证进程 9408 已退出，随后命令核实仅保留用户编辑器 36624。

本阶段还包含表现包首次发送复用实际编码结果的改动，其独立边界检查见 [表现编码验证](release-0.12-visual-encode.md)。主线程仍承担约 19 ms 的快照采样以及物理与表现开销；后台 JSON 的净收益需由同一正式运行时的七端、500 单位对照确定，不能由搬走一个函数直接推算总体 FPS。
