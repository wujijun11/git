# 2026-10-26 学习模式发布（Windows 1.5.0）

## 下载并使用

- **FPGA下载**：[ContestFull_LearningMode1024.fs](ContestFull_LearningMode1024.fs)。在Gowin Programmer中选择GW5AT-60B、SRAM Program；断电后需重新下载。
- **Windows蓝牙软件**：[TangNeonStudio-Windows-1.5.0.zip](TangNeonStudio-Windows-1.5.0.zip)。下载后完整解压，打开TangNeonStudio/TangNeonStudio.exe，保留_internal。
- **可维护主工程**：[full/ContestFull.gprj](../../full/ContestFull.gprj)。本次已验收位流由同源隔离构建生成，快照关闭GAO，保留原CST/SDC。
- **完整用法**：[等候学习模式](../../docs/等候学习模式_20261026.md)。选择内置或25键映射曲谱，在演奏页点击“等我弹对”；先松开全部琴键，按齐目标才进入下一组。
- **灯板安装**：[AHCT125接线](../../hardware/ahct125/README.md)与[25灯校准](../../hardware/led25/README.md)。灯板需独立5V供电和共地，不能只接IN/GND。

## 本版范围

包含滑条四区菜单、1024条曲谱事件、Windows/手机曲库搜索和MIDI导入、Windows推荐刷新与电脑键位自定义、模式回传、蓝牙队列改进、直接MIDI音高播放、Windows后台实时曲谱播放、5×5灯位编号及FPGA实体按键等候学习。直接音高模式使用板上当前音色，不改变实体25键映射。

学习模式仅在本次Windows客户端提供入口，手机与C3不需为学习功能重刷。C3源码包含此前的BLE转发改进；现有实物固件是否需要更新应核对版本，不自动烧录。曲谱/录制在RAM中，断电不保留。本次学习不考核节奏、力度和声学音准。

## 验证边界

19项ModelSim、9组JS业务回归、5组浏览器回归和Windows打包自检通过。高云时序Setup/Hold违反端点为0；最小Setup只有**0.002ns**，Hold为0.063ns，余量很紧。Logic 27557/59904、Register 18094/60780、BSRAM 104/118、DSP等效51.5/118。PRIMARY/LW均8/8。

尚未对本次LearningMode位流进行真实板卡、灯板、BLE教学流程和长期稳定性验收；整机≤10ms/≤5ms延迟也未测。构建仍保留CK3000、PR1014等警告，不宣称整机已达标。原始报告见[验证结果](验证结果.md)和[evidence](evidence/)。

## 复现

在TangMega60K_Synth根目录，用已有项目Python运行：

```powershell
./scripts/verify-learning-mode.ps1 -Python C:/path/to/python.exe -Build
node desktop/tests/test_learning.cjs
node desktop/tests/test_learning_ui.cjs
```

ModelSim和Gowin路径可通过脚本参数指定。Windows源码构建见[桌面说明](../../desktop/README.md)。大部分旧docs/README按日期保留历史状态，以本发布说明和实际选择的文件哈希为准。

提交前再次运行的客户端检查与测试台修正见[提交前复核](提交前复核.md)。
