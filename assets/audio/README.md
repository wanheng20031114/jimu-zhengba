# 中世纪 RTS 音效库

21 类、54 个独立变体，统一 **48 kHz、单声道、PCM16 WAV**。新库不含背景音乐或环境循环。真实 CC0 拟音与项目自制合成层的来源严格区分，许可与处理说明见 `CREDITS.md`。

运行接口：`soundbank.json` 给出 kind → 文件名列表，所有文件位于本目录。`audio_manifest.json` 给出每个文件的时长、活动 RMS、整段 RMS、采样峰值、4 倍过采样真峰值、来源、处理记录与 SHA-256。

| kind | 变体 | 时长 | 活动 RMS |
| --- | ---: | --- | ---: |
| sword_swing | 3 | 0.365–0.415 s | -20.0 dBFS |
| sword_hit | 4 | 0.65 s | -20.0 dBFS |
| bow_release | 3 | 0.39 s | -20.0 dBFS |
| arrow_hit | 3 | 0.40 s | -20.0 dBFS |
| wood_hit | 3 | 0.56 s | -20.0 dBFS |
| catapult_release | 2 | 0.96 s | -20.0 dBFS |
| stone_hit | 3 | 1.10 s | -20.0 dBFS |
| cannon_shot | 2 | 2.15 s | -18.5 dBFS |
| explosion | 2 | 1.85 s | -18.5 dBFS |
| footstep_dirt | 4 | 0.38 s | -24.0 dBFS |
| horse_hoof | 4 | 0.40 s | -24.0 dBFS |
| cart_wheel | 3 | 0.77 s | -24.0 dBFS |
| death_fall | 3 | 0.85 s | -20.0 dBFS |
| collapse | 2 | 2.45 s | -20.0 dBFS |
| ui_select | 2 | 0.18 s | -22.0 dBFS |
| ui_order | 2 | 0.23 s | -22.0 dBFS |
| ui_recruit | 2 | 0.45 s | -22.0 dBFS |
| ui_denied | 2 | 0.31 s | -22.0 dBFS |
| coin | 3 | 0.48 s | -22.0 dBFS |
| victory | 1 | 1.04 s | -22.0 dBFS |
| defeat | 1 | 0.96 s | -22.0 dBFS |

活动 RMS 使用 20 ms 音频块，统计能量在最响块 20 dB 范围内的片段；这是便于短音效匹配的测量，并非 LUFS。全部成品活动 RMS 与目标相差不超过 0.01 dB。普通战斗为 −20 dBFS、炮/爆炸为 −18.5 dBFS、UI/金币/胜负为 −22 dBFS、步伐/马蹄/车轮为 −24 dBFS。战斗 4 倍真峰值不高于 −3 dBTP，UI 和移动音效不高于 −6 dBTP；54 个文件均无削波，首尾采样为零。

调用时按种类随机选择变体，并使用有限复音和距离衰减。不要把每个单位的每次脚步同时按全音量叠加；最终总线音量、远近衰减与限幅在游戏音频场景中调整。素材活动 RMS 相近不等于并发混音已经完成。

重建：安装 `numpy scipy soundfile` 后，在项目根目录执行 `python tools/build_audio.py`。所需的 81 份原始 CC0 录音随 `sources/` 保存，可以完全离线重建。没有运行时音频合成或网络依赖。

验证范围：逐文件检查 WAV 格式、帧数、峰值、4 倍真峰值、活动/整段 RMS、首尾、直流偏移、起音延迟、频带分布和唯一哈希。81 份源文件均逐字节对照原始下载包 SHA-256 核实；全部成品起音在 3.8 ms 内，最大直流偏移 0.000342，最高 4 倍真峰值为 −3.49 dBTP。四个剑击变体超过 6 kHz 的能量占比已收束到 3.6%–11.5%，保留金属主体的辨识度。旧版单文件和 ambient 资源已移除。

本次没有向系统扬声器播放，也不将数值检查称为人工试听。运行时混音使用 Godot 原生总线捕获另行验证，素材活动 RMS 与混音后听感需区别看待。
