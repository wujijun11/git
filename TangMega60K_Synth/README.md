# 弦光：Tang Mega 60K 队长工程

当前里程碑：**04 — V2来源识别与三维全局表情接口**。原V1工程和测试音源保留，队员可逐步迁移。

新接口及迁移说明：[接口V2与队员迁移](docs/接口V2与队员迁移.md)。新工程为`TangMega60K_Synth_V2.gprj`，顶层`captain_system_top_v2`。已实现表情参数控制与提交，实际幅度/弯音/颤音运算仍由正式音源引擎实现。

第三阶段入口：[测试音源、波形与试听说明](docs/第三阶段-测试音源.md)。独立诊断工程为 `ToneDemo.gprj`，不会替换队友对接顶层。

这是一份可综合、可仿真的控制与音频输出工程，还不是能够直接烧录发声的整机工程。
目标器件为 GW5AT-60B / GW5AT-LV60PG484AC1/I0；对应 Sipeed Tang Mega 60K。
尚未添加实际底板引脚、PLL、SDC及合成引擎。当前顶层有大量内部对接端口，不能直接作为板级引脚顶层烧录。

## 从哪里开始

1. 新开发在GOWIN打开`TangMega60K_Synth_V2.gprj`；旧队员代码继续使用`TangMega60K_Synth.gprj`也可以。
2. V2集成顶层是`rtl/captain_system_top_v2.v`；原`rtl/captain_system_top.v`是V1集成边界。二者都不是物理板级顶层。
3. 第二阶段先看 `docs/第二阶段-I2S使用说明.md`，再看 `rtl/i2s_tx.v`。
4. `sim/tb_i2s_tx.sv` 用模拟样本源和独立串行接收器验证第二阶段，不需要板子或队友代码。
5. 第一阶段继续保留：`rtl/voice_allocator.v`、`sim/tb_voice_allocator.sv` 与 `docs/接口与第一课.md`。
6. 请两位队员共同确认这两份接口说明；64个声部在队员A处混成左右两个输出声道。

## ModelSim 显示波形

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
计分必须等完整音频引擎完成后实测。

## 自动验证

在项目根目录的 PowerShell 中运行：

```powershell
./scripts/test.ps1
```

脚本默认寻找C盘ModelSim，实际安装位置通过`-ModelSimBin`指定。本机另提供`./scripts/test-iverilog.ps1`，默认寻找`C:\iverilog\bin`，也可用`-IcarusBin`指定。
使用项目自己的 `sim/modelsim_local.ini`，不修改之前配置的共享 GW5A 库。
RTL没有例化高云原语，因此本阶段不需要GW5AT仿真库。
脚本依次验证V1分配、V1 I2S、测试音源、V2控制、V2 I2S、V2兼容六组。新增通过标志是`ALL V2 CONTROL TESTS PASSED`、`ALL V2 I2S TESTS PASSED`和`ALL V2 LEGACY TESTS PASSED`。Icarus结果在`sim/iverilog_results/`。原WAV导出脚本读取`sim/tone_samples.csv`，不会自动读取Icarus新目录；不要将旧CSV当作新测试结果。

GOWIN仅综合：

```powershell
& 'C:/Gowin/Gowin_V1.9.12_x64/IDE/bin/gw_sh.exe' scripts/synth.tcl
```

V2使用同目录的`scripts/synth-v2.tcl`，单独生成V2综合报告。

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

1. 队员A按 `sample_valid/ready` 接入实际逐样本合成引擎；当前测试数据仅用于接口验证。
2. 队员B按V2说明接入来源编号、表情快照、事件FIFO与传感器；队员A接入样本计算边界和active参数，完成真实表情运算。
3. 核对实际 NEO Dock 版本、原理图和 DAC 要求，建立音频时钟及复位，补齐板级顶层、CST/SDC。
4. 完成布局布线和时序检查后再上板；测实际发声、64频率谱峰及传感器到音频输出延迟。

官方资料：
- https://wiki.sipeed.com/hardware/zh/tang/tang-mega-60k/mega-60k.html
- https://github.com/sipeed/TangMega-60K-example/tree/main/audio_i2s

注意：检查时官方 `audio_i2s` 目录只有标记TBD的README，不能将它当作已经提供的完整音频工程。
