# git

Initial repository.

## FPGA 竞赛项目：弦光

[Tang Mega 60K 队长工程](TangMega60K_Synth/README.md)：基于 Sipeed Tang Mega 60K 的实时多音色合成电子乐器项目。

截至 2026-10-08，项目已实现 FPGA HDL 的 64 声部音源、正弦/风琴/八成分钢琴音色、全局表情参数处理，以及 48kHz、24 位立体声标准 I2S 输出；FM 电钢琴和反馈延迟为可选功能。板载按键演奏已通过 PCM5102A DAC → PAM8403 功放 → 无源喇叭完成实物发声验证。当前新增的 16 音逐个播放入口已完成仿真、布局布线和 SRAM 下载，实物试听反馈待确认。完整实体键床、独立表情传感器和演奏输入到声音输出的延迟实测仍待完成。

当前实板使用 [16 音逐个播放工程](TangMega60K_Synth/boardseq16/BoardSequence16_48kI2S.gprj)：KEY0 启动 MIDI 60～75 循环，KEY1 停止，KEY2 复位静音。源码、音源 ROM、构建脚本和验证记录均在项目目录；编译产物与工具安装包不随源码提交。

- [项目使用说明](TangMega60K_Synth/README.md)
- [完整音源逻辑工程](TangMega60K_Synth/AudioEngine_V2.gprj)
- [板载按键演奏工程](TangMega60K_Synth/boardkeys48/BoardInstrumentB48kI2S.gprj)
- [16 音逐个播放与验证](TangMega60K_Synth/docs/hardware/16音逐个播放测试-20261008.md)
- [V2控制与I2S接口工程](TangMega60K_Synth/TangMega60K_Synth_V2.gprj)
- [V2接口与队员迁移说明](TangMega60K_Synth/docs/接口V2与队员迁移.md)
- [团队协作与代码合并](TangMega60K_Synth/docs/团队协作说明.md)
- [控制接口约定](TangMega60K_Synth/docs/接口与第一课.md)
- [I2S 接口与仿真操作](TangMega60K_Synth/docs/第二阶段-I2S使用说明.md)
- [验证记录与范围](TangMega60K_Synth/docs/验证记录.md)
