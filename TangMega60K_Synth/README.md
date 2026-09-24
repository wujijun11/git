# 弦光：Tang Mega 60K 电子乐器工程

当前里程碑：**06 — 64声部音源与24位标准I2S输出**。内部与默认输出均为24位PCM，采用Philips I2S、每声道32位槽。DDS、ADSR、正弦/风琴/八成分钢琴音色、三维表情、混音和延迟均在FPGA内实现；FM电钢琴是可选音色。

2026-09-24：合入队员B的V2按键/和弦/表情输入与事件FIFO，新增统一逻辑顶层 `instrument_system_v2`，已接入当前含队员A八成分钢琴的音源。在 `AudioEngine_V2.gprj` 选择该顶层即可综合；`key_timbre/chord_timbre=2` 选择钢琴，设置顶层 `FM_ENABLE=1` 后可选音色3。复测入口为 `scripts/test-interaction.ps1`（Icarus）及 `scripts/test.ps1 -ModelSimBin <安装目录>`（ModelSim）。合并范围与验证见[队员B合并记录](docs/队员B合并记录-20260924.md)。统一逻辑顶层尚未接到实物键盘/传感器，不能直接作为板级烧录顶层；既有48kHz板级工程继续使用独立自检事件源。

2026-09-23：合入队员A的四音区八成分钢琴音色（`event_timbre=2`），保留正弦/风琴及可选FM音色。音源的参数ROM和离线模型、仿真入口见[八成分分区钢琴](docs/八成分分区钢琴.md)，主工程验证见[合并记录](docs/队员A八成分合并记录-20260923.md)。当前板级Live64自检仍固定使用原音色，原有GAO/I2S位流也尚未按新音源重编译；要听到新钢琴音色，需后续加入可选择音色的事件输入、重编译并连接外置DAC验证。主工程保留已修复启动欠载的I2S发送器。

2026-09-23：新增独立 `clock48/BoardAudio48kI2S.gprj`，把既有64声部与49.152MHz时钟接到PMOD1候选引脚，输出标称48kHz、24位标准I2S。启动、停止、再次启动与复位仿真及布局布线已通过；外部DAC已到货但尚未接线，引脚方向和模拟输出尚未实测。原GAO入口和位流保持不变。见[48kHz外置I2S预备工程](docs/hardware/48kHz外置I2S预备工程-20260923.md)。

2026-09-23：新增独立 `clock48/BoardAudio48kGAO.gprj` 板级验证入口，底板50MHz经两级PLLA生成标称49.152MHz音频时钟。实物SRAM下载后，三份4096点GAO采集均通过48kHz频率比与24位标准I2S时序检查，64声部运行时错误、故障及欠载为0。前两次采集之间的配置变化原因尚未查明；已知断电重接后的第三次采集经重新下载恢复。外置DAC尚未接入。见[48kHz板级验证记录](docs/hardware/48kHz时钟与I2S板级验证-20260923.md)。

启动欠载已增加首样本预备状态修复，播放期间仍检测真实缺帧；同时将GAO自检复位改为寄存器输出。新版已SRAM下载，两次实物采集64声部、欠载/错误/故障均为0，自动启停15→80轮。见[启动欠载修复](docs/hardware/启动欠载修复-20260923.md)。

2026-09-23：新增 `BoardAudioGAO.gprj`，已完成SRAM下载和两次实物GAO采集：64声部运行，自动启停完成次数从29增至120，错误/粘滞故障均为0；内部24位标准I2S时序检查通过。外置DAC及模拟输出仍待验证。见[GAO板内验证记录](docs/hardware/GAO板内验证-20260923.md)。

2026-09-22：新增 `BoardAudioDiagnostic.gprj`，顶层 `board_audio_diagnostic_top`，已把板级按键和状态灯接入既有64声部主音源，供DAC到货前做数字自检。采用50MHz，实际采样率48,828.125Hz；还不是最终48kHz外接DAC发声入口。已完成布局布线，保留PR1014时钟布线警告；实物验收尚待完成。见[主音源板级接入](docs/hardware/主音源板级接入-20260922.md)。独立 `BoardBringup.gprj` 保留用于基础按键/灯光排查，详见[板级验证记录](docs/hardware/板级验证-20260922.md)。

2026-09-19最终选择：工程仅保留24位标准Philips I2S输出，已移除PT8211模式参数、发送分支及专用测试脚本。干声和延迟顶层使用同一标准I2S接口，需连接支持该格式的DAC；不能直接驱动仅支持LSBJ的PT8211。参见[标准I2S恢复记录](docs/恢复24位标准I2S-20260919.md)。

当前音频工程为 **`AudioEngine_V2.gprj`**，默认使用干声顶层 **`audio_system_v2`**；需要50ms反馈延迟时选择`audio_system_v2_delay`。合并与验证说明见[音源合并记录](docs/音源合并记录-20260918.md)，详细算法见[音频引擎V2实现与接线](docs/音频引擎V2实现与接线.md)。

2026-09-19已增量合入队员A的64音现场自检：在GOWIN打开 `Live64_Diagnostic.gprj` 并选择 `live64_system_top` 顶层，可使用原音源生成64个不同音高并通过24位标准I2S输出。它是独立诊断入口，正常演奏顶层与公共V2接口保持不变；自检切入正常演奏系统时仍需实现事件入口独占与尾音回收。见[自检接入说明](docs/64音现场自检与接入.md)和[本次合并验证记录](docs/Live64合并验证-20260919.md)。

公共接口沿用[接口V2与队员迁移](docs/接口V2与队员迁移.md)。`TangMega60K_Synth_V2.gprj` / `captain_system_top_v2`继续保留作为队长控制与I2S接口工程，不包含完整音源。

第三阶段入口：[测试音源、波形与试听说明](docs/第三阶段-测试音源.md)。独立诊断工程为 `ToneDemo.gprj`，不会替换队友对接顶层。

这是一份可综合、可仿真的控制与音频输出工程，还不是能够直接烧录发声的整机工程。
目标器件为 GW5AT-60B / GW5AT-LV60PG484AC1/I0；对应 Sipeed Tang Mega 60K。
板级数字自检已有底板引脚约束和SDC；标称48kHz音频时钟已在独立GAO工程中完成板内验证。PMOD1外置DAC候选引脚已有独立工程，实物接线与模拟输出尚待验证；键床扫描与踏板管理仍待完成。当前`audio_system_v2`音频顶层仍接收内部事件/表情接口，不能直接作为板级引脚顶层烧录；50MHz诊断使用`BoardAudioDiagnostic.gprj`，48kHz片内数字验证使用`clock48/BoardAudio48kGAO.gprj`，外置I2S入口使用`clock48/BoardAudio48kI2S.gprj`。

## 从哪里开始

1. 完整音频开发在GOWIN打开`AudioEngine_V2.gprj`，选择`audio_system_v2`顶层；单独控制接口开发仍可打开`TangMega60K_Synth_V2.gprj`。
   实物48kHz数字验证打开`clock48/BoardAudio48kGAO.gprj`；此入口仅在片内采集I2S，尚无外置DAC引脚。
   DAC到货后的外置I2S测试打开`clock48/BoardAudio48kI2S.gprj`，先核实J8实物针脚、电平和模块供电，再连接DAC。
2. 完整音频连接见`rtl/audio/audio_system_v2.v`；其内部实例化原`rtl/captain_system_top_v2.v`及A的`voice_engine`。这些都不是物理板级顶层。
3. 第二阶段先看 `docs/第二阶段-I2S使用说明.md`，再看 `rtl/i2s_tx.v`。
4. `sim/tb_i2s_tx.sv` 用模拟样本源和独立串行接收器验证第二阶段，不需要板子或队友代码。
5. 第一阶段继续保留：`rtl/voice_allocator.v`、`sim/tb_voice_allocator.sv` 与 `docs/接口与第一课.md`。
6. 队员B按V2接口接入`event_*`和`expr_*`；64个逻辑声部已在音源内混成左右两个输出声道。所有模块共用音频系统时钟，默认要求49.152MHz以输出48kHz音频。

## ModelSim 显示波形

当前64声部标准I2S音源可在Transcript执行以下命令，自动编译、运行自检并打开Wave；结束后保留窗口：

```tcl
cd {C:/Users/asus/Desktop/Git/TangMega60K_Synth}
do sim/waves_audio_v2.do
```

请替换为自己的工程路径。脚本通过后自动保存波形、布局和摘要，每次结果独立放在 `sim/audio_results/gui_时间戳_编号/`。重新测试只需再次执行 `do sim/waves_audio_v2.do`。结果与波形阅读方法见[ModelSim波形检查](docs/ModelSim波形检查-20260918.md)。

查看已有Live64波形时，按[加载说明](docs/Live64合并验证-20260919.md#已保存波形的加载)设置 `live64_project_root`，再执行 `do "$live64_project_root/sim/view_live64_wave.do"`。脚本选择最新的已完成记录，以明确路径加载 `checked.wlf`。波形产物不随Git上传，新克隆须先获得本地仿真结果。以下是原第二阶段独立I2S接口测试的查看方式。

在 ModelSim Transcript 输入（使用当前项目的独立 work 库）：

```tcl
cd {D:/your-workspace/git/TangMega60K_Synth/sim}
do waves_i2s.do
```

脚本运行前110 us，并放大到41～64 us附近，查看第一个非零左右声道样本。
请将示例路径替换为你自己电脑的实际目录。要继续执行完整测试，在 Transcript 输入 `onfinish stop; run -all`；出现 `ALL I2S TESTS PASSED` 后停在 `$finish` 是正常结束。
左声道为 `7fffff`，右声道为 `800000`。操作和波形含义见第二阶段说明。
若要回看第一阶段，将最后一行换成 `do waves.do`。

`active_count` 包括按住与释放尾音占用的声部，不等于当前可闻振荡器数量；
计分仍需实际板卡上验证同时可闻的振荡器数量和输出采样率。

## 自动验证

在项目根目录的 PowerShell 中运行：

```powershell
# 原控制/I2S的六组回归
./scripts/test-iverilog.ps1

# 完整音源单元、4/64声部、I2S和PCM分析（路径改成自己的安装目录）
./scripts/test-audio.ps1 -ModelSimBin 'D:/msim/modelsim_ase/win32aloem'
```

脚本默认寻找C盘ModelSim，实际安装位置通过`-ModelSimBin`指定。本机另提供`./scripts/test-iverilog.ps1`，默认寻找`C:\iverilog\bin`，也可用`-IcarusBin`指定。
使用项目自己的 `sim/modelsim_local.ini`，不修改之前配置的共享 GW5A 库。
原V2音源RTL没有例化高云原语；独立48kHz板级工程使用Gowin PLLA及其仿真模型，验证方法见[48kHz板级验证记录](docs/hardware/48kHz时钟与I2S板级验证-20260923.md)。
原控制回归脚本依次验证V1分配、V1 I2S、测试音源、V2控制、V2 I2S、V2兼容六组。V2通过标志是`ALL V2 CONTROL TESTS PASSED`、`ALL V2 I2S TESTS PASSED`和`ALL V2 LEGACY TESTS PASSED`。Icarus结果在`sim/iverilog_results/`。原WAV导出脚本读取`sim/tone_samples.csv`，不会自动读取Icarus新目录；不要将旧CSV当作新测试结果。

GOWIN仅综合：

```powershell
& 'C:/Gowin/Gowin_V1.9.12_x64/IDE/bin/gw_sh.exe' scripts/synth.tcl
```

V2使用同目录的`scripts/synth-v2.tcl`，单独生成V2综合报告。

完整音频工程的综合命令（从工程根目录执行）：

```powershell
& 'C:/Gowin/Gowin_V1.9.12_x64/IDE/bin/gw_sh.exe' scripts/synth-audio.tcl
# 可选：开启延迟的顶层；该运行会覆盖同一impl目录内的综合报告
& 'C:/Gowin/Gowin_V1.9.12_x64/IDE/bin/gw_sh.exe' scripts/synth-audio-fx.tcl
```

ROM数据已随源码提供；更改采样率时必须同步调整时钟、引擎参数和ROM生成配置。仿真CSV是验证输出，不是板上发声音源。

## 已实现的策略

- 最低编号空闲声部优先。
- V1按音符编号识别；V2按`(event_source,event_note)`识别。同一来源仍按住的相同音符重触发复用声部，不同来源的同音独立分配和释放。
- 松键后发送release命令；收到引擎的完成握手才释放槽位。
- 同音符旧尾音仍在释放时再次按下：另取空闲槽位。
- 满载的新音符被拒绝，同时输出 `full_pulse`；不硬切尾音。
- 未按下音符的松键事件忽略；力度0的note-on按note-off处理。
- 引擎未准备好时，命令内容保持稳定，输入通过ready反压。
- 接口暂定1～64个声部，ID_WIDTH必须能表示声部编号；当前工程为64/6。

## 下一阶段

三人协作、提交范围与合并步骤见 [团队协作说明](docs/团队协作说明.md)。

1. 队员A的音源已经接入，继续做上板音质、音色切换及64声部频谱验证。
2. 队员B按V2说明接入25键扫描、力度、来源编号、表情快照和事件FIFO；共同定义延音踏板及全音停止语义。当前同一来源仍按住的同音高重触发会复用声部，不能仅延后note-off就声称支持踏板下同音无限叠加。
3. 核对实际 NEO Dock 版本、原理图和 DAC 要求，建立音频时钟及复位，补齐板级顶层、CST/SDC。
4. 完成布局布线和时序检查后再上板；测实际发声、64频率谱峰及传感器到音频输出延迟。

官方资料：
- https://wiki.sipeed.com/hardware/zh/tang/tang-mega-60k/mega-60k.html
- https://github.com/sipeed/TangMega-60K-example/tree/main/audio_i2s

注意：检查时官方 `audio_i2s` 目录只有标记TBD的README，不能将它当作已经提供的完整音频工程。
