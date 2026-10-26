# 时序与触摸延迟本地测试位流

仅保存在`codex/timing-latency-oled`测试分支；未合并或推送main，未下载板卡。

解压`ContestFull_TimingTouch_TEST1024.zip`得到.fs，Gowin Programmer选择GW5AT-60B、SRAM Program。
源代码提交：`330f34028e0790d5f8341b7e97c6fa8eed019f43`，工程位于仓库`TangMega60K_Synth/full/ContestFull.gprj`。

Setup/Hold余量0.168/0.166ns；24项ModelSim检查通过。完整记录见`TangMega60K_Synth/docs/时序余量与触摸I2S延迟技术总结_20261026.md`。
触摸状态到I2S数字延迟约1.302～2.867ms，不含真实MPR检测/滤波、DAC或声学延迟，不能宣称整机已满足≤5ms。

.fs SHA256：`0B74A521A1BD29E0353451AF4630302DCD0B235A5B3FC753CEA027175ACD9C20`。
.zip SHA256：`DA168F941FD245A0E6C6CA3CEAAA5559F3E25007475781244518A330F2B0DEDC`。
