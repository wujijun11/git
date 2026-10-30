# 开关式延音独立测试版：尚未上板测试

日期：2026-10-30。分支：`codex/sustain-20261030`，基于Chord F571 `df6e8f6`。
本次发布不合并main，不替换原F571发布包，不自动烧录板卡。

## 下载

| 文件 | 用途 |
|---|---|
| [FPGA位流、冻结GUI源码与验证证据](ContestFull_ChordSustain_TEST1024.zip) | 解压后`fpga/ContestFull_ChordSustain_TEST1024.fs`，UserCode `0x00007D2F`。 |
| [Windows完整便携包1.5.2-sustain-test](TangNeonStudio-Windows-1.5.2-Sustain.zip) | 完整解压后运行TangNeonStudio.exe，保留_internal文件夹。 |
| [Android APK 1.9-sustain-test](TangSynthRemote-1.9-Sustain-20261030.apk) | versionCode11；可安装APK，C3固件本次不变。 |
| [校验清单](SHA256SUMS.txt) | 下载文件SHA256及包内位流校验。 |

## 增加的功能

- 新增开关式延音，默认关闭。滑条左端长按→声音→第四区延音→关闭/开启。
- Windows和Android可控制延音，显示板上回读状态；原F571不支持时禁用新开关。
- 延音关闭时释放已经松键的保留声部，仍按住的声部继续；全部停止会清除延音。
- 64声部满载时不偷音，关闭延音并等待尾音回收后才有空槽。

保留原八成分钢琴、可选FM、固定增益和弦、实际峰值保护、触摸提前上报、曲谱/学习、
OLED/HDMI和灯板接口。公共V2、49.152MHz音频时钟、48kHz、24位Philips I2S不变。

## 验证状态

**新增延音尚未上板测试，不能据此宣称整机已达标。**

此前实际执行的34项ModelSim入口、21条客户端检查和完整Gowin构建已通过；证据见
[技术说明](../../docs/开关式延音与蓝牙控制实现说明_20261030.md)及[分析结果](../../docs/reports/sustain-20261030/analysis.json)。
Setup/Hold最小余量1.165/0.126ns，BSRAM107/118、DSP56/118；未增加PLL或外部引脚。
本次接口文档整理未改HDL，没有重复运行EDA，不把历史通过项伪装成新测试。

待实测包括：新增延音听感、真实BLE与后台播放、OLED新增延音页面、5×5灯板映射及联合指引、
多次冷启动和长期稳定性。已有OLED基本正常的用户反馈不代替新增页面验收。
用户2026-10-30反馈旧Flash启动已修复，具体方法未提供；不是宣称本延音版本修复了启动故障。

## 原理与学习资料

- [完整延音技术说明及复现命令](../../docs/开关式延音与蓝牙控制实现说明_20261030.md)
- [全部源码分层与职责](../../docs/模块分层_20261030/README.md)
- [97个模块、1465个端口的输入输出说明](../../docs/模块输入输出_20261030/README.md)
- [发布范围与保护核对](../../docs/延音测试版发布记录_20261030.md)
- [原F571回退包](../chord-touch-20261028/README.md)

冻结ZIP内部“未推送”等字样是最初本地打包时状态，保持封存文件及SHA256不变；
当前Git分支补充了本次接口文档和发布说明。原始analysis.json中的pushed=false也保留历史含义，
当前发布元数据以本目录manifest.json和远端Git提交为准；hardwareTested始终为false。
