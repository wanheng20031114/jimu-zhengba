# 中世纪音效来源与修改说明

当前运行库由 81 份保留原样的 CC0 音源和项目自制数字合成层构成，生成 21 类、54 个 WAV 变体。所有第三方素材均来自下列作者发布页面，下载日期为 2026-09-08；没有使用 Sonniss、付费素材、要求单独授权的录音或背景音乐。

| 音源包 | 作者 | 许可 | 原始发布页 |
| --- | --- | --- | --- |
| Impact Sounds 1.0 | Kenney | CC0 1.0 Universal | https://kenney.nl/assets/impact-sounds |
| Interface Sounds 1.0 | Kenney | CC0 1.0 Universal | https://kenney.nl/assets/interface-sounds |
| Fantasy Weapons and Apparel SFX Library | Vehicle / Jan Schupke | CC0 1.0 Universal | https://opengameart.org/content/fantasy-weapons-and-apparel-sfx-library |

许可根据作者发布页及下载包内原始说明核实。CC0 允许商业使用、修改及再分发，无署名要求；这里保留作者信息以明确来源。完整 CC0 法律文本保存在 `licenses/CC0-1.0.txt`，作者原始包内说明保存在各 `sources` 子目录的 `License.txt` 或 `readme.txt`。上表链接指向作者发布原页；`sources.json` 保留核验日期和下载地址。[CC0 原始许可页面](https://creativecommons.org/publicdomain/zero/1.0/)亦可直接查阅。

`sources.json` 记录各包的下载 URL、原始压缩包 SHA-256、文件字节数，以及所有保留音源的 SHA-256。`audio_manifest.json` 逐个记录成品使用的原始文件、处理操作与最终哈希。未使用的下载音频已经移除，`sources/.gdignore` 使原始音源只用于离线建库，不被 Godot 重复导入或作为运行资源加载。

处理包括：单声道混合、48 kHz 多相重采样、裁除静音、少量变速移调、高低通均衡、分层剪辑、首尾淡化、按活动区 RMS 调整增益与柔和控制瞬态峰值。剑击末级采用 4 阶 4.8 kHz 低通，控制多个金属击打叠加时的高频密度。上述处理由 `tools/build_audio.py` 确定性执行。

合成层为本项目自制：挥剑空气声、弦线振动、低频冲击主体、炮声压力爆发、爆炸低频尾声、灰尘噪声和金币短共振。它们不是下载录音，不标称为实录或第三方开源素材。马蹄音是木/石脚步拟音组合，未使用或声称使用真实马匹录音；死亡声为装备和身体跌落拟音，不含人声。胜负提示是短敲击/落地提示，不含旋律或 BGM。

此前旧版单文件合成音效属于项目自制；完成引用切换后已从运行资源目录移除，包括旧背景音乐和风声。新生成器不再生成这些旧资源。历史版本仍可通过 Git 查看。
