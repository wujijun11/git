# 弦光：Tang Mega 60K 实时多音色电子乐器

[项目说明](TangMega60K_Synth/README.md) · [完整工程与验收状态](TangMega60K_Synth/docs/全功能工程与官网验收-20261011.md) · [首次上板步骤](TangMega60K_Synth/docs/全功能首次上板步骤-20261011.md)

2026-10-11：完整竞赛入口为 `TangMega60K_Synth/full/ContestFull.gprj`，顶层 `board_contest_full_top`。音频由 FPGA HDL 逐样本实时合成，不使用预录 PCM/WAV 音源；蓝牙桥只传送控制事件。

- 64 个独立声部，正弦、风琴、八成分钢琴和 FM 电钢琴四种音色，ADSR、增益、弯音和颤音。
- 48kHz、24位立体声 Philips I²S，PCM5102A DAC → PAM8403 功放 → 喇叭；运行时延迟、混响和合唱。
- 25键电容琴键与四电极滑条，三块 MPR121 独立总线；琴键和滑条的 Gerber、设计源文件及接线图随源码提供。
- 25灯 WS2812 脱机曲谱指引、内置曲谱和用户曲谱上传、演奏事件记录与导出。
- Android APK 源码、ESP32-C3 BLE/UART 桥源码，以及 HDMI 波形、64频点分析和左右声道 XY 显示。

完整 FPGA 仿真、布局布线及时序检查通过，手机 APK 与蓝牙桥固件已编译。此次复查修复了曲谱重映射卡音、蓝牙写入悬挂、旧连接回调和同音高多指释放等问题，见[工程复查记录](TangMega60K_Synth/docs/工程复查与优化-20261011.md)。

**实物状态：原发声链已试听；新完整入口、25键/滑条、BLE、LED及HDMI整机仍待验收。** 当前 BSRAM 为114/118（97%），最小建立余量仅0.001ns；触摸到模拟输出的≤10ms基础指标、≤5ms扩展指标与确定性均未实测证明。触摸力度固定100，不能称为压力感知；记录保存音符事件，不保存完整表达/音效，用户数据断电丢失。

源码、ROM、测试和重建脚本在 `TangMega60K_Synth/`。工具安装器、许可证、缓存、编译产物、私人订单与本地 EDA 账号数据库不随源码提交；原生文件夹工程的账号归属字段已在发布副本中清空。可运行 `scripts/export-contest-full.ps1` 生成含位流、APK、报告及哈希清单的本地交付包。

- [团队分工与协作](TangMega60K_Synth/docs/团队协作说明.md)
- [音源工程](TangMega60K_Synth/AudioEngine_V2.gprj)
- [手机端说明](TangMega60K_Synth/mobile/README.md)
- [蓝牙桥说明](TangMega60K_Synth/firmware/ble_bridge/README.md)
- [琴键装配与接线](TangMega60K_Synth/hardware/touch25/assembly_wiring_zh.md)
- [滑条设计与接线](TangMega60K_Synth/hardware/slider4/README.md)
