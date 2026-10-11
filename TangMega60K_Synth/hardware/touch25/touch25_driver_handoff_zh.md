# Touch25 驱动交接与调试方案

本文件是 **R1 面板的装配与驱动交接说明**。核对日期：2026-10-11。MPR121 RTL 已实现并通过四组自动仿真；完整工程已接入该驱动。实物校准、板卡版本/管脚核对、下载和端到端延迟验收仍未完成。面板铜、接口和 MIDI 映射保持现有版本。默认参数、测试与条件时序预算见 [MPR121 实现说明](../../docs/mpr121-implementation.md)。

新的 [board_contest_full_top](../../rtl/board/board_contest_full_top.v) 经 [instrument_full_system](../../rtl/instrument_full_system.v) 将触摸、手机和曲谱事件仲裁到队列与声部控制器，沿用 FPGA 实时音源和 PCM5102A 输出。触摸驱动位于事件接口上游，不直接修改音源内部状态。原 `board_instrument_b_48k_i2s_top` 仍保留为板载按键音频入口，不含新触摸采集。

## 最小可交付范围

当前实现包含 [I²C 事务层](../../rtl/sensors/i2c_register_master.v)、[每模块初始化/采样层](../../rtl/sensors/mpr121_sampler.v)、[25 键事件适配层](../../rtl/sensors/mpr121_key_eventizer.v) 与 [四电极滑条](../../rtl/sensors/mpr121_slider.v)。到货后仍应先验收一块模块的初始化、读状态、note-on/off，再扩展三块；已有音频入口可用于对照排查。

| 模块 | 连到面板 | 启用通道 | 软件状态 mask | 全局键号 | MIDI |
|---|---|---|---|---|---|
| #1 | J1 pin1–8 | ELE0–7 | `16'h00FF` | 0–7 | 60–67 |
| #2 | J2 pin1–8 | ELE0–7 | `16'h00FF` | 8–15 | 68–75 |
| #3 | J3 pin1–9 | ELE0–8 | `16'h01FF` | 16–24 | 76–84 |

每块使用独立 SCL/SDA/IRQ，另接 3.3V 和共地。三个总线独立时地址可以相同，但每块地址仍需核对 ADDR 实际接法。驱动输入应参数化地址，不以商品标题代替电气检查。[NXP AN3895：串行通信](https://www.nxp.com/docs/en/application-note/AN3895.pdf)

原 `clock48/board48k_i2s.cst` 没有 MPR121 端口约束；完整工程的 [contest_full.cst](../../full/contest_full.cst) 已根据官方 31004 底板资料分配三组 SCL/SDA/IRQ。此候选约束不代替用户实物底板版本与导通核对，尤其不能将不同底板编号视为自动兼容。已用的 DAC 管脚仍是 BCLK=Y21、LRCLK=AB21、DATA=AA20；板载 KEY 管脚属于 1.5V I/O，不能用作 MPR121 的 3.3V 接口。

## 初始化和稳定读取

每模块独立完成以下步骤，并保存初始化阶段、读回值、错误计数和在线状态：

1. 检查总线空闲与地址 ACK；按需要软复位，然后进入 Stop。
2. 写入显式的基线过滤、触摸/释放阈值、采样/过滤、充电参数和 GPIO 禁用配置，不能依赖全零复位配置自动产生可用触摸结果。
3. 对可静态读回的配置逐项校验；完整方案启用 12/8/9 个连续电极，MPR1 ELE8–11 用作滑条，琴键软件 mask 仍为 8/8/9；关闭近接通道，读回 ECR=`8C/88/89`。ECR 表示启用数量，**不是软件 mask**。[NXP AN3944：初始化顺序与电极数量](https://www.nxp.com/docs/en/application-note/AN3944.pdf)
4. 在无人触摸时等待基线稳定，记录 filtered/baseline/delta。通过检查后才开放该模块的 note-on。
5. 当前实现从 `0x00` 连续读至 `0x2A`，共43字节，包含状态、filtered、baseline；先提取故障位，再应用表中 mask，只提交完整、成功的状态快照。不能把未用通道、近接或故障位映射成琴键。[NXP MPR121 Rev.4，§5.2–5.4](https://www.nxp.com/docs/en/data-sheet/MPR121.pdf)

未用 ELE 输入保持未启用；明确写 `GPIO Enable(0x77)=0`，不要将它们改成输出或 LED 驱动。软件 mask 和硬件禁用都要有，不能只做其中一个。[NXP AN3894：GPIO 使能与方向](https://www.nxp.com/docs/en/application-note/AN3894.pdf)

IRQ 为低有效信号，进入工作时钟域前用同步器；调度器检查同步后的**电平**，不要只等下降沿。增加定期状态读取作为补充，并对事务、重试和模块无成功读取的时间设上限；状态一直不变可以是正常长按或静置，不能仅因没有触摸变化判离线。IRQ 持续低或高都不能让状态机无限等待。读取状态处理触摸中断，不能把“IRQ 没变化”等同于“没有按键”。[NXP AN3892：触摸状态与 IRQ](https://www.nxp.com/docs/en/application-note/AN3892.pdf)

当前 RTL 默认 I²C 400 kHz、完整43字节事务超时5 ms、最多额外重试2次；上一完整快照被接受后等待0.5 ms，或低 IRQ 提前开始下一次读取。默认时钟下完整事务仿真为1.062968 ms，因此0.5 ms不是快照采样周期。三条总线并行，某块超时不阻塞另外两块。`5D=20`保持合法最短 SFI4/ESI1ms；传感器内部过滤、轮询相位和真实触摸阈值均使物理延迟不同于纯数字预算。

SDA/SCL 的 FPGA 输出用“拉低/释放”实现，外部上拉至 3.3V；核对模块已有上拉，避免重复堆叠。逐字节检查从机 ACK，读最后一字节由主机送出的 NACK 是正常结束，不能误判故障。[NXP AN3895：ACK 与多字节读](https://www.nxp.com/docs/en/application-note/AN3895.pdf)

## 接入 B V2 与故障释放

正常路径为：完整模块快照 → 25 位键状态 → 状态差分 → 有序 note-on/off → `instrument_full_system` 中的事件仲裁、FIFO 与声部控制器。

按模块分别保存最近成功状态，不把三块不同时间的读数称作同一瞬间采样。组装方式为 `{module3[8:0], module2[7:0], module1[7:0]}`，键号 `k` 默认对应 MIDI `60+k`。触摸键使用独立 source `25+k`（25–49），曲谱使用0–24，手机使用63；不能让25个触摸键共用一个 source。按下时捕获音符与音色，因此持键期间改映射不会破坏匹配释放。固定 velocity100 是演奏策略，不是真实力度；音色采用当前配置。

`valid=1 && ready=0` 时保持事件和全部字段不变，直到接受。当前触摸事件 FIFO 默认64项，并在接受批次前预留容量；完整快照保留到接收成功，不覆盖已经承诺的释放事件。自动仿真覆盖25键变化、持续背压、故障组释放与100个匹配事件；持续无限背压仍会暂停后续采样，不能保证恢复轮询之间所有物理边沿。

| 故障 | 处理约定 |
|---|---|
| 地址/寄存器/数据阶段无 ACK、总线超时、配置读回不符 | 丢弃此次不完整快照；有界重试，持续失败使该模块离线，报告具体阶段 |
| `0x01[7]` OVCF | 禁止该模块产生新 note-on；记录过流并释放故障组持键，锁存到系统reset；查 REXT/模块后再复位，不盲目反复清标志 |
| OOR、ACFF、ARFF | 记录通道与配置；仅在已启用自动配置/重配置时按其语义判断，持续异常隔离相应模块或通道 |
| 上游确实丢事件/无法保证 note-off | 使用明确的全局静音/复位兜底，并锁存原因；普通模块离线不应走这一全局路径 |

OVCF 会使芯片停止；写 1 清除后才能重新配置运行。OOR 是自动配置范围检查状态，不能把它当成任意噪声检测器。[NXP MPR121 Rev.4，§5.2、§5.12](https://www.nxp.com/docs/en/data-sheet/MPR121.pdf)

某模块离线时，只为**该模块**可能已进入事件流水线的持键产生匹配 note-off，另外两组仍按住的键保持原状态。按顺序完成已承诺的事件与故障释放，不能先把整张持键表清零再漏掉 note-off，也不能在 `ready=0` 时撤换已经呈现的事件。恢复要重新初始化、读回并完成无人触摸校准；建议先等故障组实测为释放再接受新按下，防止重连误触发。

## 校准与验收

阈值来自**最终装配状态的逐键实测**：同时记录无人触摸噪声、轻触、持续按住和释放的 delta。分别设置 touch/release，touch 高于 release，并留出噪声与轻触之间的余量。若两者重叠，先处理接线、供电或覆盖材料，不靠无限增大消抖掩盖。MHD/NHD/NCL/FDL 应与持续持键和环境变化一起验证。[NXP AN3892：阈值与消抖](https://www.nxp.com/docs/en/application-note/AN3892.pdf)、[AN3891：基线过滤](https://www.nxp.com/docs/en/application-note/AN3891.pdf)

验收至少覆盖：

- 25 个单键一一对应 MIDI60–84；保持、释放、快速重复，无重触发或卡音。
- 边界键 G4/G#4/A4（模块 #1/#2）、D#5/E5/F5（#2/#3）分别单触和同时触摸；比较单模块与三模块运行。
- C/E/G 和跨模块和弦；25 位状态同时变化的仿真、背压期间按下再释放、音源满声部时仍正确释放。25 键输入可检测不代表音源同时容纳 25 个声音。
- 保持健康模块的键，拔掉或模拟 NACK/OVCF 的另一模块；只有故障组释放，健康组不误释放，恢复不自动发新音。
- 注入未用通道、近接、OVCF 位；不得生成多余音符。模拟 IRQ 漏事件、常低和常高；轮询与超时仍可推进。
- 功放断电/通电及不同音量、线材固定前后、覆盖材料和多人触摸；记录误触和漏触。
- 分别量采样、总线、事件等待和 DAC 模拟输出的完整延迟。无逻辑分析仪/示波器等合适测量条件时，只报告仿真与试听结果，不声明已达 ≤10 ms。

## 附录：实现时容易写错的寄存器与数据

以下数值是位域解释或调试候选，**不是已经验收的整套初始化表**；具体参数必须读回和实测。

| 项目 | 约定 |
|---|---|
| Soft reset | `0x80 ← 0x63` |
| Stop | `0x5E ← 0x00`，普通配置在 Stop 写入 |
| Run ECR | `CL=10`、近接关闭，当前键盘+滑条方案 #1/#2/#3=`0x8C/0x88/0x89`；最后写入 |
| filtered_i | 地址 `0x04+2*i` 的低/高字节：`((high & 3)<<8) | low` |
| baseline_i | 地址 `0x1E+i`：`baseline_raw8 << 2`，再与 filtered10bit 比较 |
| delta_i | 有符号 `baseline10 - filtered10`，避免无符号减法下溢 |

地址、位域与数据宽度按 [NXP MPR121 Rev.4，§5](https://www.nxp.com/docs/en/data-sheet/MPR121.pdf)；`CL=10` 使用首个测量的高五位初始化基线，后续基线跟踪仍须按过滤配置验证。

`0x5D` 中 ESI/SFI 决定滤波更新节奏。复位值 `0x24` 是 ESI16 ms、SFI4；可用 `0x20` 作为 ESI1 ms、SFI4、全局 CDT0.5 µs 的调试起点。这并不使完整响应时间等于 1 ms，也不证明触摸→声音低于 10 ms。充电电流/时间须适合本面板及引线；不能只缩短 ESI。[NXP AN3890：过滤与时序](https://www.nxp.com/docs/en/application-note/AN3890.pdf)

采用自动配置时，USL/LSL/TL 依实际 VDD 计算；FFI 与过滤配置一致，BVA 与 ECR 的 CL 一致，并记录实际 CDCx/CDTx 与配置失败状态。初次调试可先在无人触摸阶段运行自动配置，再验证持续按住时不会因重配置吞掉音符；不要未经测试便开启无限自动重配置。[NXP AN3889：充电与自动配置](https://www.nxp.com/docs/en/application-note/AN3889.pdf)

建议保留每模块 `online/init_stage/last_success_age/error_count/OVCF/OOR`，每键 `filtered/baseline/delta/touch` 和全局 `pending_events/backpressure/dropped_events`。快照诊断与音符事件解耦，不能因低速显示或日志堵住释放通路。

参考文件：[mapping.csv](mapping.csv) 为物理/MIDI 映射；[assembly_wiring_zh.md](assembly_wiring_zh.md) 为装配接线；[MPR121 实现说明](../../docs/mpr121-implementation.md) 记录模块接口与测试；[完整工程](../../full/ContestFull.gprj) 使用新的触摸接入入口。实际下载前核对完整工程布局时序报告、底板版本及3.3V接线；本文件不代表已经完成这些实物验收。
