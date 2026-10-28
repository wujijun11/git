# 和弦稳定混音＋触摸提前上报：本地测试版

[完整测试包](ContestFull_ChordStable_EarlyTouch_TEST1024.zip)包含FS、完整GUI源码、54项仿真报告、完整时序、PCM与同标度钢琴对照WAV。

- [单独FS](../../delivery-chord-touch/fpga/ContestFull_ChordStable_EarlyTouch_TEST1024.fs)：GW5AT-60B，SRAM Program，UserCode `0x0000F571`。
- [实现说明](../../docs/和弦稳定混音与触摸提前上报实现说明_20261028.md)：模块分工、原理、问题修正与复现命令。
- [数值对照](../../docs/reports/chord-touch-20261028/analysis/对照结果.md)：普通两音的保持音分量由约50%恢复为约100%，四个数字仿真场景节省约0.94～0.96ms。
- [旧版回退文件](../../delivery-menu-hierarchy/fpga/ContestFull_MenuExpression_TEST1024.fs)：UserCode `0x00003DF3`，保持原文件不变。

实际过载仍会压缩，不能承诺任意和弦完全不失真。本版未下载、未上板，真实总延迟与听感待实测；旧版OLED基本功能已获用户反馈，不代替本版实测，5×5灯板仍待实测。没有宣称修复核心板熄灯或供电异常。没有推送远端。

源码记录：`b06bc97`（含功能提交`2a39e90`及封存校验修正），独立分支`codex/chord-gain-stable-20261028`。FS和ZIP的SHA256见`manifest.json`与`SHA256SUMS.txt`。
