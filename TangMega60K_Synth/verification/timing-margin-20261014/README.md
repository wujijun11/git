# 2026-10-14 时序余量优化

当前源码已采用第二轮 `payload-select`。Gowin完整综合、布局布线和STA通过，最小Setup余量由 **0.051ns提高到0.272ns**，增加0.221ns；Logic减少378，BSRAM仍为106/118。Hold最小余量由0.065ns变为0.035ns，仍为正但偏紧，因此不能将这次结果描述为所有时序都宽裕。

## GitHub归档范围

仓库提供本次受验源码、复现脚本、原始构建/STA/资源报告、两次Core运行清单与日志、两组等价专项日志，以及最终审计结果。完整候选树、厂商模型、工具库、编译数据库、位流和波形保留在原机，不随Git提交；下文中的绝对路径和这些产物路径属于原运行记录。原始JSON与日志保留原样，未把中断记录改写为单次通过。

`selected-release.json`记录原机456项审计；`verify-selected-release.py`依赖原机完整快照与受保护的旧实现，精选归档不能直接重跑该历史审计。新克隆应按文末命令重新执行Core、两组专项与隔离构建，产生新证据。需要自行安装ModelSim、Gowin和Python 3.11以上；脚本分别支持`-ModelSimBin`/`-VendorModel`和`--gowin`指定工具路径。受验输入和归档证据通过`.gitattributes`保留原始字节，避免Git换行转换改变SHA256。

## 改了什么

1. `rtl/control/remote_note_watchdog.v`：提前计算持音集合及排除当前音符后的非空判断，让迟到的仲裁接受信号只参与最终标量选择，避免经过128位动态更新与归约。首个NoteOn与释放同拍、最后NoteOff与释放同拍、背压、晚到音符重扫和同音符释放确认优先级保留。
2. `rtl/control/remote_command_router.v` 与 `rtl/instrument_full_system.v`：新增不含复位门控的 `performance_pending`，仅用于选择曲谱命令的opcode/payload；有效信号、接受条件、本地ready和复位行为仍使用原条件。复位信号不再穿过载荷选择和256行有效性校验后进入回复状态寄存器。
3. 两份旧TB显式空接新增状态输出，新增两组冻结reference和独立等价专项。没有改变音源、25键、音色、声部数、RAM容量、引脚、时钟频率或CST/SDC约束，没有加入额外流水线等待。

## 完整布局布线结果

| 指标 | 优化前 | 第一轮：持音判断 | 第二轮：再分离载荷选择（已采用） |
|---|---:|---:|---:|
| Setup最小余量 | 0.051ns | 0.119ns | **0.272ns** |
| Hold最小余量 | 0.065ns | 0.052ns | **0.035ns** |
| Recovery最小余量 | 6.957ns | 8.583ns | 8.207ns |
| Removal最小余量 | 0.669ns | 0.357ns | 0.386ns |
| Setup/Hold违规端点 | 0/0 | 0/0 | 0/0 |
| Logic | 22346 | 22356 | **21968** |
| Register | 15322 | 15322 | 15322 |
| BSRAM | 106/118 | 106/118 | **106/118，约90%** |
| DSP | 50.5/118 | 50.5/118 | 50.5/118 |
| 音频域Fmax / 目标 | 49.276 / 49.152MHz | 49.442 / 49.152MHz | 49.818 / 49.152MHz |
| 最差Setup逻辑级数 | 23 | 17 | 16 |

第二轮实际完整构建在2026-10-14 20:03:16至20:18:45执行（北京时间），耗时928.743秒，退出0。最差Setup已移到 `performance/record_ram` 输出至 `event_velocity[1]`，前两处目标瓶颈退出最差路径。71条已有Gowin警告仅归一化快照路径后与基线完全一致，没有新增警告；既有时钟关系/PR1014提示仍保留。

原始证据：

- [优化前最终报告](../modelsim-20261014/build_snapshot_20261014_124217/build-results.json)
- [第一轮报告](build_scalar-nonempty_20261014_194501_f7aeeb65/build-results.json)
- [第二轮报告](build_payload-select_20261014_200315_8e6fbc97/build-results.json)
- [第二轮原始STA](build_payload-select_20261014_200315_8e6fbc97/full/impl/pnr/ContestFull.tr)
- [警告比较](build_payload-select_20261014_200315_8e6fbc97/warning-comparison.json)

第二轮先在隔离源码树构建，当时主工程仍是第一轮，所以其原始 `build-results.json` 保留 `mainProjectInputsMatch=false`。随后精确复制两份生产RTL和两份TB至主工程，见 [采用记录及备份路径](promotion.json)。采用后独立核对80份当前构建输入全部与第二轮快照匹配，原 `full/impl` 的25个文件及文件集合保持原样；最终审计另外记录当前匹配结果，不改写历史报告。

## 功能验证

两组专项已在ModelSim实际通过，均包含故障注入来检查判定器能识别退出码为0的Fatal：

- [Watchdog逐拍等价](../timing-20261014/watchdog-equivalence-evidence.md)：3个seed，共68,171拍（60,000随机拍），全部128音符及同音符接受/释放确认优先级、背压、重扫、超时和heartbeat边界。
- [Router与曲谱控制器逐拍等价](../timing-20261014/router-performance-equivalence-evidence.md)：3个seed，共31,044拍（30,000随机拍），公共输出/ACK/曲谱metadata/row_written/RAM一致，覆盖PERF_WAIT异步复位、本地与远端竞争、连续写入/提交。小容量仅用于专项TB，生产容量仍是256行曲谱、1024条事件记录。

第二轮核心回归先完成28项，包含整机64声部、MPR121、25灯点阵、音效、视频、N4音源81,187样本。运行中断时I2S尚未完成，原始manifest仍保留 `Running`，不能视为整套通过：

- [原28项日志与清单](modelsim_payload_select/run_20261014_200705_ffd383c2/test-summary.json)
- [补跑I2S及4项非法参数检查](modelsim_payload_select_resume/run_20261014_213338_49354631/manifest.json)
- [最终逐项与哈希审计](selected-release.json)：`ReleaseAccepted=true`，456项检查全部通过，固定Core33项均有实际完成日志。两次仿真各107份语义输入与当前主工程匹配，80份构建输入及新位流/时序/资源报告哈希匹配，原实现25份文件与集合不变；不生成虚构的单次完整通过记录。

最后5项补跑全部通过：I2S用时693.99秒，完成64声部10,862帧，非零10,859帧，启动欠载0、稳定播放欠载增量0，背压3,322,025拍；4项非法LED参数正确拒绝。由原28项与补跑5项合计覆盖固定Core33项，29项正常测试和4项预期拒绝测试均有完整原始日志。ModelSim编译错误/警告为0，整机运行仍有38条未连接状态输出警告，I2S运行错误/警告为0。

首轮另一次I2S曾达到600秒墙钟超时，原证据保留；第二轮及补跑使用1200秒上限，没有缩减刺激或断言。额外双音源N64逐样本长测沿用用户先交付Core的选择，未续跑，不能声明Full34项通过。优化版整机保存波形已在ModelSim的Wave窗口实际打开。

## 新位流和复现

本次新位流位于原机 `build_payload-select_20261014_200315_8e6fbc97/full/impl/pnr/ContestFull.fs`（相对本记录目录，不随Git上传），SHA256：

`254da4e07b353939ca25289664921a7a95e598e55c2a8d39f0344331ddb84141`

新位流尚未下载到板子。原 `full/impl/pnr/ContestFull.fs` 保留旧版本，不能当作此次优化版；旧导出脚本会因源码比旧时序报告新而拒绝导出。后续下载应使用上面的明确路径。数字仿真与STA不代替实物音频、触摸/LED/蓝牙联调和延迟测量。

在主工程根目录重新仿真：

```powershell
.\scripts\test-modelsim-full.cmd -Suite Core -TimeoutSeconds 1200
.\scripts\test-modelsim-watchdog-equivalence.cmd
.\scripts\test-modelsim-router-performance-equivalence.cmd
```

在ModelSim Transcript打开已通过整机测试的保存波形：

```tcl
do {C:/Users/asus/Desktop/Git/TangMega60K_Synth/verification/timing-margin-20261014/modelsim_payload_select/run_20261014_200705_ffd383c2/view_full_system.do}
```

从当前源码重新做完整隔离构建：

```powershell
python .\scripts\build-contest-isolated.py --variant timing-recheck
```

每次创建新目录、冻结生产输入并保护原实现。每项通过必须同时满足明确的完成标记、正确Fatal判定及输入哈希检查，单凭进程退出0或生成位流都不算验收通过。
