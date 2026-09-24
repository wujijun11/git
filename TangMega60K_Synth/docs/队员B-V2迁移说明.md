# 队员B V2迁移说明

## 现有代码与V2差异

旧`interaction_top`只处理17位事件：`event_on/event_note/event_velocity/event_timbre`。
V2新增6位`event_source`，队长按`(source,note)`匹配 held voice，因此B侧必须在note-off时送回
note-on时的原source和原note。

旧代码只有音符事件FIFO，没有全局表情通道。V2新增独立`expr_*` ready/valid通道，每次传输完整快照：
`expr_gain`、`expr_bend_cents`、`expr_vibrato_cents`。

旧代码不保存和弦展开结果。V2要求持键期间切换调性或和弦模式时，松开仍释放按下时展开出的原音符。

## 本次新增文件

- `rtl/event_fifo_v2.v`：23位事件FIFO，布局为`{on, source[5:0], note[6:0], velocity[6:0], timbre[1:0]}`。
- `rtl/interaction_top_v2.v`：V2交互边界，包含按来源保存的按键音符、事件FIFO、和弦展开记忆、溢出/反压遥测和表情快照输出。
- `sim/tb_interaction_v2.sv`：V2交互联合测试，实例化B侧边界和队长`captain_control_top_v2`。
- `sim/run_interaction_v2.do`：ModelSim入口。

未修改队长公共接口文件：`captain_control_top_v2.v`、`voice_allocator_v2.v`、`expression_controls_v2.v`。

## 来源编号表

当前边界支持两种输入形态：

| 来源范围 | 建议用途 | 说明 |
|---:|---|---|
| 0..24 | 25个物理演奏键 | 一键一source；同音不同键可独立分配与释放 |
| 25..31 | 和弦/功能键槽 | `chord_id`用于保存按下时展开列表；输出source使用`chord_source` |
| 32..63 | 预留 | 演奏垫、外部MIDI、测试源或后续传感器 |

本次RTL不声明已完成真实25键扫描、ADC、触摸传感器、踏板或去抖。板级适配层仍需实现输入同步、过滤和标定，
并在`valid=1 && ready=0`时保持valid和所有负载稳定。

普通按键以`in_source`作为稳定的物理来源编号。模块会在note-on真正进入FIFO时保存该来源的note和timbre，
note-off会使用这份快照，因此持键期间切换调性不会松错音。由于V2没有独立`key_id`，上游不能在同一次按下/松开之间改变`in_source`；
若物理来源编号也会变化，公共协议需要增加独立按键标识。

主工程合并修复（2026-09-24）：同一 `in_source` 或 `chord_id` 在仍按下时收到重复 note-on，输入会确认该事件但不再次入队，也不改写第一次按下保存的音符快照。松键仍使用原快照。需要真正重新触发同一来源时，应先发送并完成松开事件。

## 接口连接示例

```verilog
wire event_valid, event_ready, event_on;
wire [5:0] event_source;
wire [6:0] event_note, event_velocity;
wire [1:0] event_timbre;
wire expr_valid, expr_ready;
wire [11:0] expr_gain;
wire signed [12:0] expr_bend_cents;
wire [7:0] expr_vibrato_cents;

interaction_top_v2 u_inputs (
    .clk(clk), .rst_n(rst_n),
    .in_valid(key_event_valid), .in_ready(key_event_ready),
    .in_on(key_event_on), .in_source(key_source),
    .in_note(key_note), .in_velocity(key_velocity), .in_timbre(key_timbre),
    .chord_valid(chord_valid), .chord_ready(chord_ready),
    .chord_on(chord_on), .chord_id(chord_id), .chord_source(chord_source),
    .chord_count(chord_count), .chord_notes_flat(chord_notes_flat),
    .chord_velocity(chord_velocity), .chord_timbre(chord_timbre),
    .event_valid(event_valid), .event_ready(event_ready),
    .event_on(event_on), .event_source(event_source),
    .event_note(event_note), .event_velocity(event_velocity),
    .event_timbre(event_timbre),
    .expr_update_valid(expr_update_valid), .expr_update_ready(expr_update_ready),
    .expr_update_mask(expr_update_mask),
    .expr_update_gain(expr_update_gain),
    .expr_update_bend_cents(expr_update_bend_cents),
    .expr_update_vibrato_cents(expr_update_vibrato_cents),
    .expr_valid(expr_valid), .expr_ready(expr_ready),
    .expr_gain(expr_gain), .expr_bend_cents(expr_bend_cents),
    .expr_vibrato_cents(expr_vibrato_cents),
    .fifo_level(), .fifo_full(), .event_backpressure(),
    .overflow_pulse(), .overflow_sticky(), .overflow_count(),
    .pushed_count(), .event_count(),
    .current_expr_gain(), .current_expr_bend_cents(),
    .current_expr_vibrato_cents()
);

captain_system_top_v2 u_system (
    .clk(clk), .rst_n(rst_n),
    .event_valid(event_valid), .event_ready(event_ready),
    .event_on(event_on), .event_source(event_source),
    .event_note(event_note), .event_velocity(event_velocity),
    .event_timbre(event_timbre),
    .expr_valid(expr_valid), .expr_ready(expr_ready),
    .expr_gain(expr_gain), .expr_bend_cents(expr_bend_cents),
    .expr_vibrato_cents(expr_vibrato_cents),
    /* cmd/done/sample/I2S ports connect as before */
);
```

`expr_update_mask`定义：bit0更新gain，bit1更新bend，bit2更新vibrato。任意单项变化都会输出完整三参数快照。
复位默认值为gain=2048、bend=0、vibrato=0。

## 验证入口

ModelSim：

```powershell
./scripts/test.ps1 -ModelSimBin 'D:/msim/modelsim_ase/win32aloem'
```

单独运行V2交互：

```tcl
cd {D:/FPGA_workplace/git/TangMega60K_Synth/sim}
do run_interaction_v2.do
```

覆盖场景：不同来源同音、普通键与和弦在持键期间切换调性后按原快照释放、重叠和弦独立松开、
握手后上游立即改写和弦负载、FIFO反压及溢出遥测、三参数独立变化、ready/valid稳定、复位默认值。

## 剩余问题

- 真实传感器型号、扫描矩阵、ADC/触摸接口、电平标准和板级引脚尚未接入。
- 去抖、压力滤波、弯音零点标定、颤音旋钮标定需要在板级适配层完成。
- V2仍没有all-notes-off协议；note-off不能静默丢弃，异常恢复只能依赖系统复位或后续公共协议扩展。
