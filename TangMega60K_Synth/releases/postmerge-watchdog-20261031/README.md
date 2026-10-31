# 合并后延音看门狗修复版

2026-10-31。修复远程延音在全部松键后失联仍持续、力度0事件错误占用看门狗两处问题。
兼容现有Windows1.5.2、Android1.9与C3固件，无需改变接线。延音默认关闭。

[FPGA位流与冻结GUI源码](ContestFull_SustainWatchdogFix_20261031.zip) · [校验值](SHA256SUMS.txt)
· [原理与验证](../../docs/合并后代码复查与延音失联修复_20261031.md)

ZIP内fpga/ContestFull_SustainWatchdogFix.fs为本次重新完整构建的位流，source/full/ContestFull.gprj为冻结GUI工程。
source/full/rtl已带ROM副本，顶层board_contest_full_top，GAO在本构建快照中关闭。
主仓库对应源码入口仍是full/ContestFull.gprj，构建脚本为scripts/build-contest-full.tcl。

12项选定ModelSim回归、新旧看门狗随机等价对照，以及完整Gowin布局布线/时序检查通过。
Setup余量0.866ns、Hold余量0.062ns，违反端点均为0；详见报告实际数据。
本版尚未上板，未自动下载或写Flash，不将数字回归当作真实BLE/模拟音频验收。
历史7D2F与F571发布包保留，旧位流不包含本次修复。
