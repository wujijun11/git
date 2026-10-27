# OLED空闲波形本地测试交付

`ContestFull_OLEDIdleWave_TEST1024.zip`包含FS、GUI源码、24项实际ModelSim日志、完整Gowin报告、I2S/OLED真实仿真捕获及中文实现说明。

滑条静置3秒显示实际音频波形，再次触摸恢复原页面；总菜单/子页均取消闲置自动回音量。长按操作保留。

尚未上板，原R2实板可用文件保留。板载RGB仍为启动诊断灯色。

[实现说明与预览](../../docs/OLED空闲实时波形实现说明_20261027.md)。位流UserCode为0x000010C2；SHA见manifest.json及SHA256SUMS.txt。

未自动下载、未上传或合并main。
