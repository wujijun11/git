# 自动播放单音诊断

此独立工程复用单声部诊断的音源、48kHz/24位I²S和原DAC针脚。音频时钟锁定后等待2秒，自动播放一次五个纯音及16音《欢乐颂》片段，不需要按KEY0。先将功放音量调低。

KEY1停止，KEY2复位；两者也会取消尚未开始的自动播放。复位或PLL重新锁定后不会自动重播，KEY0松开再按可以手动重新播放。手动启动也消费自动播放请求。重新配置或上电才重新允许自动播放一次。

RGB由50MHz系统时钟独立更新：红色闪烁表示音频PLL未锁定；黄色闪烁表示音频仍处于复位；白色闪烁表示等待或结束；绿色闪烁表示五个纯音阶段；蓝色闪烁表示钢琴片段；红色常亮表示I²S欠载。闪烁表示内部50MHz逻辑在工作，不是对板外时钟或模拟声音的测量。

原接线BCLK=Y21、LRCLK=AB21、DATA=AA20不变；J13没有主动输出，未用引脚带上拉。主工程位流和增益保持不变。本工程的单声部增益不能用于64路混音。

构建命令（使用绝对脚本路径）：

```powershell
& 'C:/Gowin/Gowin_V1.9.12_x64/IDE/bin/gw_sh.exe' (Join-Path $PWD.Path 'scripts/build-mono-autostart.tcl')
```

2026-10-11已完成本独立工程构建和控制仿真，尚未下载此位流。构建报告的Setup/Hold违规端点均为0；时钟模型为50MHz、38.4MHz、49.152MHz，最小报告Setup/Hold余量为7.483ns/0.046ns。输出针脚报告确认BCLK=Y21、LRCLK=AB21、DATA=AA20，均为LVCMOS33、DRIVE=4。报告中的时钟数值不是板上测量，外部I²S的DAC输入Setup/Hold仍未验证。

位流为`mono_auto/impl/pnr/MonoAutostart.fs`，SHA256为`8556D30FB53C3E6B9D189C49E14E2771F4124D9A11E72BAAF77210676C5598C7`。构建、控制测试、针脚/时序报告及原`MonoDiagnostic.fs`、`ContestFull.fs`哈希保持不变的证据保存在`verification/mono-autostart-20261011/`。

短测试通过自动触发、消抖键、停止/复位、一次性消费、忙时按住KEY0、PLL失锁后不重播、50MHz心跳与无锁红色状态检查。测试中的PLL与音源为桩模块，音频时钟直接等于系统时钟，I²S输出固定为0；它不验证真实异步时钟关系、PCM、实际播放时间或音质。音源及I²S的独立完整仿真证据在`verification/audio-diagnostic-20261011/`，不能替代实际声音验证。
