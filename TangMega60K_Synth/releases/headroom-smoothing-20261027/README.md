# 自动混音增益跨档平滑：独立本地测试版

**暂停使用：2026-10-27用户实板确认该位流实体键失效、FPGA握手超时，回退原版恢复。**见`暂停使用.md`和`STATUS.json`。原ZIP保留作追查，不是已经可用或已修复的版本。

- FPGA位流：fpga/ContestFull_HeadroomSmooth_TEST1024.fs；GW5AT-60B，SRAM Program，尚未上板。
- GUI：fpga-source/full/ContestFull.gprj；请保留完整fpga-source，包括full/rtl ROM副本。
- 42项选定ModelSim及实际布局布线结果见evidence和manifest，音量/音色稳态标度保持。
- 本版不含取消的黑匣子/模式同步改动；Windows/手机/C3沿用原版，不需更新。
- analysis-n4的WAV为真实HDL短片段，original-then-smoothed先旧后新，间隔250ms，无分别归一化。
- 原位流保留；本次未下载、未上传或合并main。不能宣称现场噼啪已经解决。
- 原理、资源代价、时序边界和复现命令见实现说明.md。
