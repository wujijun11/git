# FPGA 曲谱、25 键灯光指引和事件录音

实现依据为[高云 2026 竞赛官网选题二](https://www.gowinsemi.com.cn/university/match2026)与本工程 [Remote control V1](remote-control-v1.md)。本模块只存储音符指令与毫秒时间；音频仍由 FPGA 合成引擎实时生成。没有 PCM 曲目、PCM 录音或采样回放音源。

## 控制器接口

`rtl/performance/performance_controller.v` 的默认时钟为 49,152,000 Hz。所有接口均在 `clk` 同一时钟域，`rst_n` 低有效同步状态复位。

| 信号 | 位宽与含义 |
| --- | --- |
| command_valid / command_ready | 输入请求与输出接收；ready 恒为 1，无效/忙请求通过 status 明确拒绝 |
| command_opcode / command_payload | 8 / 80 位；p0 在 payload[7:0]，多字节数小端 |
| command_status | 8 位组合结果，必须在 valid && ready 的同一上升沿采集；0 成功、1 参数错误、2 忙、3 不支持 |
| record_valid / on / source / note / velocity / timbre | 输入旁路监视；1 / 1 / 6 / 7 / 7 / 2 位，没有 ready，不会阻塞演奏 |
| event_valid / event_ready | 输出音符事件握手；反压期间 valid 和全部字段保持不变 |
| event_on / source / note / velocity / timbre | 1 / 6 / 7 / 7 / 2 位，送现有音符事件仲裁/音源 |
| key_map_flat | 175 位；第 k 键 MIDI = [7*k +: 7]；板级默认映射 MIDI60..84（C4..C6） |
| current_timbre | 当前选择音色，2 位；曲谱 note-on 使用此值 |
| guide_mask | 25 位，第 k 位对应物理第 k 键及灯条第 k 颗灯 |
| playing / recording / guide_active / overflow_sticky | 遥测标志；guide 模式 playing=0、guide_active=1 |
| record_count / score_position | 各 16 位；position 是下一条尚未完成的行号 |
| record_read_index / record_read_valid / row_payload | 16 / 1 / 80 位同步读口；输入地址在上升沿采样，该沿后输出对应 valid 与 payload；越界 valid=0、payload=0 |

参数为 `CLK_HZ=49152000`、`SCORE_CAPACITY=256`、`RECORD_CAPACITY=1024`、`SCORE_SOURCE_BASE=0`、`RECORD_SOURCE_BASE=25`。容量范围为 1..65535；source base 必须使 base+24≤63。曲谱 RAM 每行 45 位，录音 RAM 每行 64 位，不重复存索引与保留字节。均采用同步读：曲谱一写一读，录音一个写/回放读口加一个独立读回口；RAM 内容及读数据不复位以支持块 RAM 推断。有效行标志及数量在复位时清零。回放来源合法性在录音写入时增量锁存单 bit，没有遍历整块录音 RAM 的组合读逻辑。

## 命令与时间

仅处理 04 TRANSPORT、06 SCORE_WRITE、07 SCORE_COMMIT。08 READBACK 由上级路由器通过同步读口完成，控制器直接收到 08 时返回不支持；上层须给定索引并等待一个采样沿后的 valid/payload，不能使用此前地址的结果。非法保留字节也返回参数错误。

| TRANSPORT action | 行为 |
| --- | --- |
| 0 stop | 停曲谱/回放/指引，并有序释放本模块已经输出的持键；不停止正在进行的录音 |
| 1 score play | 当前已提交曲谱输出音符，同时驱动灯光 |
| 2 record start | 清旧录音及录音错误标志，开始新录音；忙时拒绝 |
| 3 record stop | 保留已录行，停止录音 |
| 4 record clear | 空闲且未录音时清空数量与错误标志 |
| 5 panic | 停播放、停指引、停录音，并有序释放本模块音符；全局音源 panic 由上层同时执行 |
| 6 guide start | 静音指引独立运行，完全不依赖 event_ready |
| 7 guide stop | 灯全灭；静音指引停止；如果正在有声播放，音符播放继续 |
| 8 record replay | 回放已录指令，保留录制的 MIDI、音色、力度和时间；source 重新分配 |

毫秒节拍使用相位累加 `+1000` / `CLK_HZ`，避免把 49,152 clocks/ms 截断导致长期漂移。delta 为完整无符号 32 位毫秒数，第一行相对启动时间，此后逐行累加。零 delta 可表示同拍多音。事件背压延迟交付后，调度器按原时间追赶，逐条交付，不丢弃迟到行；背压期间不能保证实际发声仍准时。毫秒计数按 32 位循环，单个 delta 最大约 49.7 天，调用方应避免在同一等待行内跨越整个计数周期。

06 每次完整写入一行，并使旧用户曲谱提交失效。07 用户提交必须满足 count>0、count≤容量且本次上传的 0..count-1 每行均已写入；不完整提交绝不开始播放。成功提交后清本次写入标志，下一批上传不能借用旧提交的行。播放、指引、停止释放及录音期间拒绝修改曲谱。内置 source=1 接受 count=0 或 32，选择贝多芬《欢乐颂》公开领域旋律的 16 音、32 条 on/off 事件。复位默认选择此内置曲目，脱离手机也可由本地控制按钮请求指引。

曲谱按物理键映射生成 MIDI。已发出的音符对应 note/timbre 会保存；即使运行中改了键位/音色，后续 note-off 与原来的 note-on 匹配。自然结束仍有持键时自动补齐 note-off。stop/panic 遇到已经呈现而尚未接受的 note-on 时继续保持该事件，待其接受后再发送匹配 off，不能撤换或吞掉。

同一键连续NoteOn时，如果新音高不同，先输出旧音高/旧音色的Off，收到握手后再输出当前行的新On；插入的释放不消费曲谱行、不改变累计到期时间。Stop/Panic可中断这一步，清旧音后不启动替换音。同音高重触发直接复用allocator已有声部，避免满声部时因释放尾音占槽而丢弃重触发。NoteOn且velocity=0按Off处理，音符归属和LED指引均遵守这一语义。

## source 空间与录音

完整入口统一分配：曲谱/回放 0..24，触摸 25..49，手机 63。手机源63可同时持有多个不同MIDI音高；不能把一个source误算为只允许一个声部。其他远程source在本入口不开放，三条路径不会重叠；Remote V1和整机路由按这个约定实现。控制器不修改公共allocator。

录音记录旁路已经被演奏路径接受的 NOTE 事件，由上层提供 `record_valid` 单周期。每行严格符合 82 响应：p0..1=index，p2..5=delta ms，p6=source，p7=MIDI，p8=velocity，p9={5'b0,timbre[1:0],on}。容量默认 1024 条；额外一条到达时停止录音并锁存 overflow，旧行保持有序，演奏旁路继续。溢出通过遥测旗标报告；不产生 ACK，因为溢出是异步录音事件。record start/clear 和复位可清该旗标。

所有 source 均可记录并回传。当前回放仅接受整份录音来源均为 25..49 的物理键；回放 source=(原 source-25)+SCORE_SOURCE_BASE，因此可与物理演奏共存。包含远程或其他来源的录音仍可读取，但回放命令返回参数错误，避免发生 source 冲突。溢出留下不完整持键时，回放自然结束的释放机制会补齐 off。录音不包含 expression、效果配置、曲谱编辑或 PCM。

## 25 灯串行输出

`rtl/performance/ws2812_guide.v` 输入 clk、rst_n、guide_mask[24:0]，输出 led_data、busy、frame_done。默认 25 颗、绿色亮度 32；按物理键 0→24，GRB、每像素 24 bit、MSB first。每帧开始锁存 guide_mask，传输途中改变输入只影响下一帧。0 高电平目标 300 ns，1 高电平目标 650 ns，每 bit 1250 ns，帧间低电平 300 µs；周期数向上取整。默认 49.152 MHz 下分别为 15 / 32 / 62 clocks，0/1 低电平为 47 / 30 clocks，锁存 14746 clocks。对应高电平 305.18 / 651.04 ns、低电平 956.22 / 610.35 ns，符合 [WS2812B-V5/W 原厂数据手册](https://datasheet.lcsc.com/datasheet/pdf/3795cfb9d54f7ec8ecc0b043ede3c05a.pdf?productCode=C2846931)的范围。旧版 80 µs 锁存及约 549 ns 的1码低电平不足，已修复。frame_done 是完整帧低电平锁存结束的单周期脉冲，与下一帧开始重合。复位立即将引脚门控为低，释放复位后先等待完整锁存间隔。其他芯片/克隆型号仍需按具体资料核对，不能把名字相近视为时序相同。

**当前自研琴键 PCB 没有 LED，需另接25颗WS2812或兼容GRB灯。** 2026-10-13新增对5×5独立点阵面板的适配：常量灯号映射、绿色曲谱提示、蓝色实体触摸、重合青色；每通道上限32/255，两种状态在帧开始一起拍快照。默认仍按DIN链序映射C4..C6，面板走线/朝向必须到货校准；详见[点阵与C3适配](../hardware/led25/README.md)。灯板尚未接入或实测，外部供电、电平转换、共地和具体芯片时序需核对，不应由FPGA GPIO给灯板供电。用户底板为31005，旧31004孔号不能当作实体接线验收结论；现有KEY的1.5V IO不适用。

## 已运行验证与限制

运行 `./scripts/test-performance.ps1`，实际 Icarus RTL 仿真通过：控制器 60 个有序音符事件；25 键独立静音指引；毫秒与分数频率计时；完整 unsigned delta32；不完整及新批次提交拒绝；键位/音色变化下匹配释放；背压保持；stop/panic 与自然结束释放；82 字段读回；录音溢出、回放 source 重映射、非法来源拒绝及复位。灯条外部信号解码分别在 20 MHz 和实际 49.152 MHz 下通过 3 帧、1800 bits，检查逐灯顺序、GRB 位序、0/1 高低脉宽、帧快照、300 µs 低电平和中途复位。新测试在旧RTL上先复现锁存过短失败，再用修复后的RTL通过。

控制器时间仿真缩小了 CLK_HZ 加速等待，同时另测非整数 clocks/ms 的分数计时；WS2812 仿真使用真实 20 MHz / 50 ns 和 49.152 MHz 时钟。此前独立综合报告验证了控制器的块 RAM 推断；灯条时序修复后的完整布局布线结果以[整机验收文档](全功能工程与官网验收-20261011.md)为准。逻辑仿真和布局布线不代表实际灯亮度、真实 BLE、触摸→声总延迟或实物验收已通过。

新增`tb_performance_retrigger.sv`与真实`voice_allocator_v2`联合验证改映射60→61的释放顺序、同音满声部重触发、音色归属、零力度、背压保持、停止/紧急静音和录制事件回放。旧代码已在最小曲谱On60、改映射、On61、Off61上复现残留held voice60；修复后自然结束时控制器及allocator持键均为0。

## NEO Dock 31004 Rev1.4 的约束提案

2026-10-11 独立下载并读取[Sipeed 官方 60K 底板原理图](https://dl.sipeed.com/fileList/TANG/Mega_138K_60K/02_Schematic/DOCK/Tang_Mega_NEO_Dock-60K_31004_Schematics.pdf)（21 页，2025-03-31，Rev1.4）和[官方全引脚 CST](https://dl.sipeed.com/fileList/TANG/Mega_138K_60K/08_Misc/tang_mega_60K_pins.cst)。入口来自[Sipeed 60K Wiki 的硬件资料](https://wiki.sipeed.com/hardware/en/tang/tang-mega-60k/mega-60k.html)。原理图 SHA256 为 `5CA6049ED80BAB57BCAA87CC5E58926F569F2CA2AA11B984D52DA1782633F976`，CST 为 `DCACED4A5D15D60A3615190138AD3522B562C82748E35FFD150139BC7542FF4C`。已视觉核对第 7、19 页。工程中 `docs/hardware/reference/Tang_Mega_138K_NEO_Dock.pdf` 是一页机械尺寸图，不能支持电气引脚分配。

下列 GPIO 都在 BANK1，官方 CST 明确设为 LVCMOS33、VCCIO=3.3V。第 19 页把 J13 标为靠 PCIe 连接器的 SDRAM0 40 针扩展口；第 7 页把 SDRAM0_D0..7、D15..12 映射到对应 60K 球号。这里的 SDRAM0 是扩展口复用名，不能同时插外部 SDRAM 模块。J14 在这份 31004 图纸标为不装，不能默认存在。PMOD0 另有板载 LED 负载，故本提案选择 J13。

| 新顶层信号（名称由集成方匹配） | J13 针号 | 图纸网络 | FPGA 球号 | 电平 |
| --- | --- | --- | --- | --- |
| mpr_scl[0] | 1 | SDRAM0_D0 | E14 | 3.3V，拉低/释放 |
| mpr_sda[0] | 2 | SDRAM0_D1 | E13 | 3.3V，拉低/释放 |
| mpr_scl[1] | 3 | SDRAM0_D2 | C15 | 3.3V，拉低/释放 |
| mpr_sda[1] | 4 | SDRAM0_D3 | C14 | 3.3V，拉低/释放 |
| mpr_scl[2] | 5 | SDRAM0_D4 | B13 | 3.3V，拉低/释放 |
| mpr_sda[2] | 6 | SDRAM0_D5 | C13 | 3.3V，拉低/释放 |
| uart_rx，接 BLE TX | 7 | SDRAM0_D6 | A14 | 3.3V 输入 |
| uart_tx，接 BLE RX | 8 | SDRAM0_D7 | A13 | 3.3V 输出 |
| mpr_irq_n[0]，可选 | 9 | SDRAM0_D15 | B16 | 3.3V 输入 |
| mpr_irq_n[1]，可选 | 10 | SDRAM0_D14 | B15 | 3.3V 输入 |
| mpr_irq_n[2]，可选 | 13 | SDRAM0_D13 | A16 | 3.3V 输入 |
| guide_led_data | 14 | SDRAM0_D12 | A15 | 3.3V 输出到灯条电平转换输入 |

IRQ 不接时需要由上层拉高或可靠输入上拉，周期轮询仍必须运行。**J13-11 为 5V_Peripheral，J13-12 为 GND；不可把 J13-11 接到 MPR121 的 3.3V 电源。** 三块 MPR121 的 3.3V 可从 PMOD1 J8-1/2 取得，GND 可从 J8-3/4 取得；图纸编号与插座实际朝向须按 pin1 标记确认。25 灯条供电独立核对，不从 FPGA 输出脚供电。

现有外置 DAC 保留：Y21=J8-11/PMOD1_IO0 的 BCLK，AB21=J8-9/PMOD1_IO2 的 LRCLK，AA20=J8-7/PMOD1_IO4 的 DATA。这三根与上表不重叠，也不与现有时钟 V22、用户键 AA13/AB13/Y12、板载 RGB J16、功放关闭 AB16 重叠。

以下是供完整板级 CST 合并的片段，本任务未改生效约束或顶层；SCL/SDA 的外部 3.3V 上拉由电路提供。

```text
IO_LOC "mpr_scl[0]" E14;
IO_LOC "mpr_sda[0]" E13;
IO_LOC "mpr_scl[1]" C15;
IO_LOC "mpr_sda[1]" C14;
IO_LOC "mpr_scl[2]" B13;
IO_LOC "mpr_sda[2]" C13;
IO_PORT "mpr_scl[0]" IO_TYPE=LVCMOS33 PULL_MODE=NONE DRIVE=4 BANK_VCCIO=3.3;
IO_PORT "mpr_sda[0]" IO_TYPE=LVCMOS33 PULL_MODE=NONE DRIVE=4 BANK_VCCIO=3.3;
IO_PORT "mpr_scl[1]" IO_TYPE=LVCMOS33 PULL_MODE=NONE DRIVE=4 BANK_VCCIO=3.3;
IO_PORT "mpr_sda[1]" IO_TYPE=LVCMOS33 PULL_MODE=NONE DRIVE=4 BANK_VCCIO=3.3;
IO_PORT "mpr_scl[2]" IO_TYPE=LVCMOS33 PULL_MODE=NONE DRIVE=4 BANK_VCCIO=3.3;
IO_PORT "mpr_sda[2]" IO_TYPE=LVCMOS33 PULL_MODE=NONE DRIVE=4 BANK_VCCIO=3.3;
IO_LOC "uart_rx" A14;
IO_LOC "uart_tx" A13;
IO_PORT "uart_rx" IO_TYPE=LVCMOS33 PULL_MODE=UP BANK_VCCIO=3.3;
IO_PORT "uart_tx" IO_TYPE=LVCMOS33 PULL_MODE=NONE DRIVE=4 BANK_VCCIO=3.3;
IO_LOC "mpr_irq_n[0]" B16;
IO_LOC "mpr_irq_n[1]" B15;
IO_LOC "mpr_irq_n[2]" A16;
IO_PORT "mpr_irq_n[0]" IO_TYPE=LVCMOS33 PULL_MODE=UP BANK_VCCIO=3.3;
IO_PORT "mpr_irq_n[1]" IO_TYPE=LVCMOS33 PULL_MODE=UP BANK_VCCIO=3.3;
IO_PORT "mpr_irq_n[2]" IO_TYPE=LVCMOS33 PULL_MODE=UP BANK_VCCIO=3.3;
IO_LOC "guide_led_data" A15;
IO_PORT "guide_led_data" IO_TYPE=LVCMOS33 PULL_MODE=NONE DRIVE=4 BANK_VCCIO=3.3;
```

这是 **31004 Rev1.4 图纸验证结果**，未确认用户手中底板丝印、连续性或外部模块电气，也未将 31005/其他版本当作已验证同版。真实接线/下载前集成方仍需按实物版本核对这张表；不能根据未采用的照片推断版本。

HDMI 补充：官方 60K CST 与第 7 页一致，D0±=J14/H14、D1±=J15/H15、D2±=K17/J17、CK±=G15/G16，均与上表、DAC 不重叠。第 15 页说明 60K 只用于 TX；该页残留的 AA22/AA23 等旁注与第 7 页 60K 映射不一致，不应直接拿它们作 60K 球号约束。本任务没有 HDMI RTL、时钟、差分约束或显示验收。

官方 CST 使用正端端口的成对 IO_LOC，IO_PORT **没有显式 IO_TYPE**；不应凭猜测添加 `TMDS` 或 `ELVDS33` 字符串。负端由 RTL 的 `TLVDS_OBUF.OB` 输出，官方文件没有负端单独约束。对应整机端口名的等价片段如下，最终需由布局布线核验实际差分对：

```text
IO_LOC "tmds_data_p[0]" J14,H14;
IO_PORT "tmds_data_p[0]" PULL_MODE=NONE DRIVE=3.5 BANK_VCCIO=3.3;
IO_LOC "tmds_data_p[1]" J15,H15;
IO_PORT "tmds_data_p[1]" PULL_MODE=NONE DRIVE=3.5 BANK_VCCIO=3.3;
IO_LOC "tmds_data_p[2]" K17,J17;
IO_PORT "tmds_data_p[2]" PULL_MODE=NONE DRIVE=3.5 BANK_VCCIO=3.3;
IO_LOC "tmds_clk_p" G15,G16;
IO_PORT "tmds_clk_p" PULL_MODE=NONE DRIVE=3.5 BANK_VCCIO=3.3;
```

## 远程掉线与事件队列集成回归

`sim/tb_watchdog_arbiter_integration.sv` 使用实际 `remote_command_router`、`remote_note_watchdog`、`note_arbiter` 和 `event_fifo_v2`，接线与 `instrument_full_system` 的命令准入方式一致。可独立运行 `./scripts/test-performance-watchdog.ps1`。已经通过 10 个有序事件：满 FIFO 中远程 NOTE 被锁定、掉线触发、已有 valid/payload 保持、恢复 ready 后释放、扫描已过的小 MIDI 新到达仍重新扫描释放、健康触摸/曲谱 source 保留、重复包 ACK/心跳不重触发、实际周期计数超时、FIFO/路由/watchdog 背压稳定及共同复位。

此测试覆盖已修复的死锁：若在 watchdog 开始释放时直接把 arbiter 的远程 in_valid 门控为 0，已经锁定的远程 grant 会永远无法完成，也无法转交 watchdog。整机改为仅阻止新命令进入 router；已经呈现的 NOTE 继续握手，watchdog 在扫描尾部发现持键仍非空时从 0 重扫。测试中延迟接受的 MIDI0 会在原扫描已经经过 0 后到达，验证了这次重扫。
