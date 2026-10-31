# 弦光：Tang Mega 60K 实时多音色电子乐器

**2026-10-31 合并后复查修复**：修复远程延音全部松键后失联不释放、力度0事件错误占用看门狗两处问题。远程拥有的延音在3秒无命令后释放，本地独立延音保持；公开协议和引脚不变，电脑/手机/C3可继续配套。[修复与验证](TangMega60K_Synth/docs/合并后代码复查与延音失联修复_20261031.md) · [新FPGA交付](TangMega60K_Synth/releases/postmerge-watchdog-20261031/README.md)。原7D2F/F571包未修改，旧位流不含本次修复；本版尚未上板。

2026-10-31 主工程整合：统一纳入队友的和弦稳定增益、触摸提前上报、分层滑条菜单及开关式延音更新。完整工程入口仍为 `TangMega60K_Synth/full/ContestFull.gprj`；配套 Windows 1.5.2-sustain-test 与 Android 1.9-sustain-test。延音默认关闭，新增延音的实物听感及长期稳定性仍待验收，C3固件与AHCT硬件设计不变。[整合范围、检查与重建说明](TangMega60K_Synth/docs/主工程合并记录_20261031.md)。下文“不合并main”等描述保留其原发布日期的历史含义。

2026-10-28：本分支新增**和弦稳定音量＋触摸提前上报测试版**。[完整FPGA测试包](TangMega60K_Synth/releases/chord-touch-20261028/README.md) · [技术实现说明](TangMega60K_Synth/docs/和弦稳定混音与触摸提前上报实现说明_20261028.md) · [本次发布与验证范围](TangMega60K_Synth/docs/降低延迟与稳定音量发布记录_20261028.md)。普通两音叠加不再仅按声部数减半，实际过载仍进行峰值保护；四个数字仿真场景节省约0.94～0.96ms，54项相关仿真及完整时序通过。本版尚未上板，真实手指到喇叭总延迟、听感与长期稳定性待实测；旧版OLED基本显示已有用户反馈，5×5灯板仍待实测。历史段落按对应日期理解。

2026-10-27：最近全部测试版本源码、问题处理与验证报告一并更新。[版本状态与问题汇总](TangMega60K_Synth/docs/版本问题与解决方案汇总_20261027.md) · [OLED波形版FPGA下载](TangMega60K_Synth/releases/oled-idle-wave-20261027/README.md) · [Windows 1.5.1下载](TangMega60K_Synth/releases/windows-minimized-20261027/README.md)。最新FPGA版已有用户发声反馈；**OLED屏幕、5×5灯板未进行实物测试**。Windows最小化专项使用真实窗口与内存设备，真实蓝牙/DAC待复测；历史故障FS仍暂停使用。下方为各自日期的历史记录。

2026-10-26：更新Tang Mega 60K当前演奏与学习版本。**[下载FPGA位流、Windows 1.5.0软件和查看验证结果](TangMega60K_Synth/releases/learning-mode-20261026/README.md)**。支持按对实体琴键才前进的学习模式；保留曲库、蓝牙、菜单和实时HDL合成。时序余量很紧，新学习功能实物验收与总延迟仍待测。下方保留历史更新。


[工程源码](TangMega60K_Synth/) · [当前状态与接线](TangMega60K_Synth/docs/当前工程状态-20261023.md) · [Windows 电脑软件](TangMega60K_Synth/desktop/README.md) · [ESP32-C3 固件](TangMega60K_Synth/firmware/ble_bridge/README.md)

2026-10-23 更新：25 键电容琴键、三块 MPR121、64 声部 FPGA 合成、24 位 I2S、曲谱与 LED、Android 控制源码及 Windows Tang Neon Studio **1.0.4**。音频在 FPGA 内实时合成，蓝牙桥传递控制事件。

完整入口为 `TangMega60K_Synth/full/ContestFull.gprj`，顶层 `board_contest_full_top`。当前主源对应完整构建 `8FE0`；另保存只增加 UART 被动观察的完整工程副本 `3B9F`，已完成 SRAM 下载与编号读回，两版构建时序违规均为 0。

**实机 BLE → FPGA ACK 尚未验收通过，FPGA 尚未完成本轮 Flash 固化。** 最近 C3 USB 与广播离线，尚缺发送查询后的片内对照。编译、软件回归、蓝牙配对或 SRAM 下载都不代表整机验收完成。详细验证范围及未完成事项见[当前工程状态](TangMega60K_Synth/docs/当前工程状态-20261023.md)。

源码、ROM、约束、测试、重建脚本、本地 BLE 修补库及许可证、精选验证报告和已脱敏的硬件设计随仓库提供。安装器、构建缓存、设备 Flash/NVS 备份、私人订单和账号恢复资料保留在本机。

- [被动 UART 观测与解码](TangMega60K_Synth/verification/uart-live-debug-20261023/README-observation.md)
- [74AHCT125 制造资料](TangMega60K_Synth/hardware/ahct125/release/README.md)

## 历史记录：2026-10-14

[项目说明](TangMega60K_Synth/README.md) · [完整工程与验收状态](TangMega60K_Synth/docs/全功能工程与官网验收-20261011.md) · [首次上板步骤](TangMega60K_Synth/docs/全功能首次上板步骤-20261011.md)

2026-10-14更新：完整竞赛入口为 `TangMega60K_Synth/full/ContestFull.gprj`，顶层 `board_contest_full_top`。音频由 FPGA HDL 逐样本实时合成，不使用预录 PCM/WAV 音源；蓝牙桥只传送控制事件。已合入25灯点阵/微雪ESP32-C3适配、块RAM优化及两轮时序优化。

- 64 个独立声部，正弦、风琴、八成分钢琴和 FM 电钢琴四种音色，ADSR、增益、弯音和颤音。
- 48kHz、24位立体声 Philips I²S，PCM5102A DAC → PAM8403 功放 → 喇叭；运行时延迟、混响和合唱。
- 25键电容琴键与四电极滑条，三块 MPR121 独立总线；琴键和滑条的 Gerber、设计源文件及接线图随源码提供。
- 25灯 WS2812 脱机曲谱指引、内置曲谱和用户曲谱上传、演奏事件记录与导出。
- Android APK 源码、ESP32-C3 BLE/UART 桥源码，以及 HDMI 波形、64频点分析和左右声道 XY 显示。

完整 FPGA 仿真、布局布线及时序检查通过，手机 APK 与蓝牙桥固件已编译。此次复查修复了曲谱重映射卡音、蓝牙写入悬挂、旧连接回调和同音高多指释放等问题，见[工程复查记录](TangMega60K_Synth/docs/工程复查与优化-20261011.md)。

最新完整Gowin构建：**Setup最小余量0.272ns，Hold最小余量0.035ns，时序违规0；BSRAM为106/118（约90%）**。相较本轮0.051ns基线，Setup增加0.221ns、Logic减少378；Hold仍偏紧。实际ModelSim核心33项全部有通过日志（首次28项加补跑5项），两组逐拍等价专项共99,215拍通过，64声部I2S欠载为0。额外双音源N64长测未续跑，不能声明Full34项通过。原始报告、日志、哈希和复现入口见[时序余量优化与证据](TangMega60K_Synth/verification/timing-margin-20261014/README.md)。

**实物状态：10月11日主工程已在板上验证播放、停止、重播与复位；本次优化版位流尚未下载。** 25键/滑条、BLE、LED及HDMI整机仍待到货验收，触摸到模拟输出的≤10ms基础指标、≤5ms扩展指标与确定性均未实测证明。触摸力度固定100，不能称为压力感知；记录保存音符事件，不保存完整表达/音效，用户数据断电丢失。

源码、ROM、测试和重建脚本在 `TangMega60K_Synth/`。工具安装器、许可证、缓存、编译产物、私人订单与本地 EDA 账号数据库不随源码提交；原生文件夹工程的账号归属字段已在发布副本中清空。仓库精选归档原始日志与结果；完整快照、位流和波形保留原机，新克隆应重新执行验证。请先在工程目录按[复现步骤](TangMega60K_Synth/verification/timing-margin-20261014/README.md#新位流和复现)生成对应源码的新位流；原 `full/impl` 为旧实现，不能作为本次优化产物导出。

- [团队分工与协作](TangMega60K_Synth/docs/团队协作说明.md)
- [音源工程](TangMega60K_Synth/AudioEngine_V2.gprj)
- [手机端说明](TangMega60K_Synth/mobile/README.md)
- [蓝牙桥说明](TangMega60K_Synth/firmware/ble_bridge/README.md)
- [琴键装配与接线](TangMega60K_Synth/hardware/touch25/assembly_wiring_zh.md)
- [滑条设计与接线](TangMega60K_Synth/hardware/slider4/README.md)
