# 单声部 DAC 诊断工程

独立工程，不替代比赛全功能工程。只驱动既有 DAC 的 BCLK=Y21、LRCLK=AB21、DATA=AA20；J13 不在顶层端口中。复用原 50 MHz → 49.152 MHz PLL，Philips I2S、24 位采样、32 位声道槽、48 kHz。

- KEY0：一次播放序列；忙时的按键忽略，按住不会循环。复位后先松开 KEY0 再按。
- KEY1：释放当前音并停止；等待引擎 done 握手清空声部。
- KEY2：复位静音。
- 先播放 E4、F4、G4、D4、C4 的正弦音，每音保持 600 ms，随后间隔 200 ms。
- 再加 1 秒静音标记，播放改编《欢乐颂》16 音片段，保持 400 ms，间隔 200 ms。

仅一个 voice 0，`MASTER_SHIFT=7`，相对全工程 `MASTER_SHIFT=1` 提高 36.12 dB。固定力度 100、gain=2048、FX/FM 关闭。每个新音必须在上个音的 done 通知被消费且间隔结束后才发出，避免单声部互相覆盖。ROM 是数学波形/合成参数，不是录音。

下载前将外部功放音量调至最低，再缓慢增加。此工程的单声部增益不能直接用于 64 声部混音。

从仓库根目录构建：

```powershell
& 'C:/Gowin/Gowin_V1.9.12_x64/IDE/bin/gw_sh.exe' (Join-Path $PWD.Path 'scripts/build-mono-diagnostic.tcl')
```

位流在 `mono_diag/impl/pnr/MonoDiagnostic.fs`。本工程不自动下载；实际下载及物理听音须另行记录。

独立仿真与 PCM 检查：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $PWD.Path 'scripts/test-mono-diagnostic.ps1')
```

测试只加速 I2S 串行时钟，保持 DDS、包络及 PCM 的 48 kHz 样本域；外部数据线解码结果与已接收 PCM 逐帧比较，并对 5 个正弦音及 16 个钢琴音做频谱核对。另检查单声部生命周期、停止/复位、长按不循环、命令背压、增益的有符号极值。证据输出在 `sim/mono_diagnostic_results/`。仿真不能代替实际喇叭听音与电气测量。
