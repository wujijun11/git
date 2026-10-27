# Windows 1.5.1：最小化窗口实时播放修复

下载[TangNeonStudio-Windows-1.5.1.zip](TangNeonStudio-Windows-1.5.1.zip)，完整解压，关闭旧版，
运行`TangNeonStudio/TangNeonStudio.exe`。左下角应显示1.5.1，`_internal`必须保留。

原生后台线程处理曲谱计时、ACK和保活；最小化时界面可以暂停刷新，音符继续发送。
保留快速音符和原250ms滞后保护，不靠丢音或放宽超时解决问题。本次无需重烧FPGA/C3。

真实Windows窗口最小化专项已执行：内存设备收到2800/2800条事件，顺序一致，
恢复窗口后状态查询成功；**真实蓝牙与喇叭尚待用户复测**。
当前FPGA版本有用户发声反馈，**OLED屏幕与5×5灯板未进行实物测试**。

[实现与复现](../../docs/Windows最小化实时播放修复_20261027.md) ·
[问题与解决方案汇总](../../docs/版本问题与解决方案汇总_20261027.md) ·
[当前FPGA包](../oled-idle-wave-20261027/README.md)。ZIP及EXE哈希见`manifest.json`与`SHA256SUMS.txt`。
