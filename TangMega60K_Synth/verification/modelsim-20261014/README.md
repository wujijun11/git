# 2026-10-14 工程优化与 ModelSim 核心回归

本记录对应当时0.051ns余量的源码快照。随后完成两轮时序优化，当前源码与最新0.272ns位流、33项回归及一致性审计见[后续时序优化](../timing-margin-20261014/README.md)；下文“当前源码”均指本次原记录的验证时点，原始证据保留。

GitHub只归档源码、脚本、小型原始日志、结果与输入清单。完整运行快照、厂商模型、工具库、位流和WLF保留原机；历史绝对路径不适用于新克隆，重新仿真可产生自己的波形与证据。原机完整审计与新环境复现的区别见[归档范围](../timing-margin-20261014/README.md#github归档范围)。

当前源码在 ModelSim Intel FPGA Starter Edition 2020.1 实际完成 **33项核心回归，33项通过**。整机64声部、64声部I2S、MPR121、25灯WS2812B、控制与音效、视频仿真均有日志证据；整机波形已经在现有 ModelSim 窗口打开。完整 Gowin 综合、布局布线和时序检查也通过。

本次验收范围按用户选择为“先完成核心回归并交付结果”。额外的双音源64声部逐样本长测没有续跑，不能据此声明全部34项通过。仿真与数字实现结果不代替实体琴键、滑条、LED、蓝牙和模拟音频的整机验收。

## 修正内容

- `rtl/control/remote_note_watchdog.v`：强制释放启动条件使用本拍接受NoteOn/NoteOff后的持音集合。修复首个NoteOn与断连释放同拍时不能立即释放，以及最后一个NoteOff与释放同拍时启动空扫描的问题。新增4个边界场景，覆盖背压、最高音符编号和还有其他持音的情况。
- `rtl/board/board_bringup_top.v`、`rtl/board/board_instrument_b_48k_gao_top.v`：调整变量声明顺序，解决 ModelSim 全工程编译的前向变量引用错误，逻辑行为不变。
- `sim/tb_video_vendor.sv`：将超时常量显式写为64位，解决 ModelSim 对超过32位无尺寸十进制常量的编译错误。
- `scripts/test-modelsim-full.ps1/.cmd`：加入独立库、输入快照与SHA256、逐项日志、波形、超时和明确通过标记。默认执行Core33项；Full包含额外N64长测，允许按精确名称筛选。四个非法LED参数用例要求指定DUT在时间0报告指定Fatal；本版ModelSim的Fatal可能返回退出码0，因此不能只检查退出码。
- `scripts/merge-modelsim-full-results.ps1`：按原始日志和源码指纹验收已有结果，保留原始Full超时记录，单独生成核心验收报告。

没有改变音源算法、音量、引脚、PLL、时序约束或RAM配置。

## 仿真证据

实际执行目录为 [run_20261014_124827_1829ac81](run_20261014_124827_1829ac81/manifest.json)。原始Full记录保持 `Passed=false`、33/34：唯一未完成项为 `audio_engine_n64`，在600.814秒墙钟超时，没有最终PASS标记。按用户选择，另生成 [核心验收manifest](core_acceptance/manifest.json)，`CorePassed=true`、`FullPassed=false`、N64为 `DeferredByUser`。

核心33项包括29项正常测试和4项预期非法参数拒绝测试。重新校验了107份项目、生产RTL（66份）、测试文件（29份）、ROM（10份）和厂商模型（1份）；当前输入与已执行仿真快照全部SHA256一致。运行器后来增加Core选择与长测超时配置，版本变化在验收manifest单独记录，没有改写旧日志或快照。

| 验证范围 | 已完成证据 |
|---|---|
| 整机 | 64个混合音色声部、表情、音效、全局静音、演奏事件记录、脱机LED引导；420个输出样本 |
| 音源与I2S | N4逐样本测试81,187样本；另有64声部I2S集成10,862帧，启动及稳定播放欠载均0，包含背压 |
| WS2812B | 三种25灯布局，共93帧串行解码；GRB颜色、曲谱/触摸、亮度上限、帧快照与复位；4项非法配置正确拒绝 |
| MPR121 | I2C、触摸前端、背压、时序、事件容量 |
| 控制与音效 | 手机UART、事件仲裁、表情合并、断连释放及仲裁集成、演奏控制、按键动作、全局静音、音效历史逐位一致 |
| 可视化与视频 | 音频跨时钟监视、可视化、TMDS编码、视频时序，以及Gowin PLLA/ODDR/差分模型串行化 |

完整逐项清单见 [核心验收清单](core_acceptance/README.md)。演奏事件记录保存音符与控制事件，不是预录PCM发声。

生产RTL和测试文件编译错误、警告均为0。整机运行时有38条未接状态输出端口警告，日志未出现Error/Fatal；其余是否有警告应以各项日志为准。构建日志仍保留已有71条Gowin警告，归一化后与前一版相同，没有新增警告。

旧watchdog已用相同新增测试复现：首个NoteOn同拍释放在60ns报错，最后NoteOff同拍释放在80ns报错；原正常路径通过。见 [修复前复现](baseline_20261014_124011/results.json)。修复后4个场景全部通过。

## 当前数字实现结果

使用 Gowin V1.9.12，目标为 `board_contest_full_top` / `GW5AT-LV60PG484AC1/I0`。本次在独立快照完整构建，未覆盖原 `full/impl`，未下载FPGA。

| 指标 | 2026-10-13基线 | 本次最终源码 |
|---|---:|---:|
| Setup最小余量 | 0.039ns | 0.051ns |
| Hold最小余量 | 0.022ns | 0.065ns |
| Setup/Hold违规端点 | 0/0 | 0/0 |
| Recovery/Removal最小余量 | 7.369/0.535ns | 6.957/0.669ns |
| BSRAM | 106/118 | 106/118（约90%，剩12块） |
| Logic | 21986/59904 | 22346/59904 |
| Register | 15322/60780 | 15322/60780 |
| DSP | 50.5/118 | 50.5/118 |

RAM占用本次没有进一步减少；历史97%不代表当前最终结果。最差Setup路径从传感事件FIFO到watchdog扫描控制，23级逻辑，余量仅51ps，仍然紧张。通过工具当前约束检查不代表已有宽裕余量，也不是实测演奏延迟。

最终构建80份输入与当前项目哈希匹配；原实现目录25个文件及文件集合保持不变。详细报告见 [最终构建记录](build_snapshot_20261014_124217/README.md) 与 [构建结果JSON](build_snapshot_20261014_124217/build-results.json)。

本次旧位流在原机 `build_snapshot_20261014_124217/full/impl/pnr/ContestFull.fs`（不随Git上传），SHA256为 `a431aa6f0e1027f52489cede424c52df311e29d4aaf94035ab0ea6472b762396`。该文件尚未下载到板子；本次没有新增实板试听或实体外设验收。

## 重跑与查看

从项目根目录执行下面一行，默认跑Core33项。CMD启动Windows PowerShell 5；本机32位ModelSim从PowerShell 7直接启动可能遇到DLL重定位错误。

```powershell
.\scripts\test-modelsim-full.cmd
```

结果存入新的独立目录，不改已有GUI工程/库。按需筛选核心单项：

```powershell
.\scripts\test-modelsim-full.cmd -Suite Core -CaseName remote_note_watchdog
```

在 ModelSim Transcript 查看本次已保存的整机波形：

```tcl
do {C:/Users/asus/Desktop/Git/TangMega60K_Synth/verification/modelsim-20261014/run_20261014_124827_1829ac81/view_full_system.do}
```

复核既有核心结果而不重新仿真：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\merge-modelsim-full-results.ps1 -BaseRun .\verification\modelsim-20261014\run_20261014_124827_1829ac81 -Suite Core -DeferLegacyN64
```

保留Full34项入口，额外N64长测默认允许7200秒，未在本次交付前续跑；测试刺激与断言没有因时间限制缩减。
