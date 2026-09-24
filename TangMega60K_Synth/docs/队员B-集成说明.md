# 队员B 集成说明（事件FIFO 与输入交互）

交付物：`rtl/event_fifo.v`、`rtl/interaction_top.v`。
本轮**没有改动任何队长文件**，集成步骤以书面 diff 提出，是否采纳由队长决定。

---

## 1. 这两个模块是什么

```text
传感器/按键          你的适配层              interaction_top            captain_control_top
   ────►   in_valid/in_ready  ────►   event_fifo   ────►   event_valid/event_ready  ────►   u_control
           in_on/note/velocity/timbre                  （字段与队长接口逐位相同）
```

`event_fifo`：参数化同步 FIFO，每个条目一个 17 位演奏事件，默认 `DEPTH=32 / AWIDTH=5`。

`interaction_top`：队员B 的集成边界，薄薄一层 —— 一个 FIFO 实例 + 四个遥测计数器。
它的 `event_*` 输出端口与 `captain_control_top.v` 上的同名端口**逐字段一致**，
所以队长可以把它直接接到 `u_control`，不必改动 `u_control` 内部任何一行。

## 2. 为什么必须排队，而不能只发一个脉冲

队长的 `event_ready` 只在 IDLE 为高。收下一个事件后，分配器要经历
SCAN（64 周期）→ DECIDE → SEND 才能再收下一个，而且 `done_valid` 还会抢占。
也就是说**收一个事件大约要 66 个时钟周期**。

而和弦按下会在极短时间内产生多条事件。若生产者只把 `valid` 拉高一个周期就撤，
第二条之后的事件会**静默丢失** —— 没有错误标志，只是少了一个音。
这正是文档里那句"B需保留待发事件或通过 FIFO 排队，不可只发送一个时钟脉冲后不管ready"。

本 FIFO 让丢事件在结构上不可能发生：**队列满时 `push_ready` 拉低**，
守规矩的生产者只会被推迟，不会被丢弃。

## 3. 事件位映射

```text
mem[i] = { on[1], note[7], velocity[7], timbre[2] }   共 17 位
           bit16  bit15:9  bit8:2     bit1:0
```

与队长的 `event_on / event_note / event_velocity / event_timbre` 逐位对应，无重排、无偏移。
打包只写在一处（`event_fifo.v` 的 `localparam EV_WIDTH` 与四条 `assign`），
日后要加宽事件（例如加 `key_id`）只动这几行。

## 4. 输入侧契约（适配层必须遵守）

未来的硬件适配层（按键扫描、触摸/压力传感器）必须满足以下四条。这四条不是建议，
是握手协议成立的**前提**，违反其中任何一条，症状都会表现为"偶尔丢音"而不是报错：

1. **`in_valid` 拉高而 `in_ready` 为低时，必须保持 `in_valid` 与四个负载字段全部不变。**
   中途改负载，FIFO 会锁存到改后的值 —— 这是真实的错音，不是仿真假象。
2. **`rst_n` 为低时不得 push。** `event_fifo` 内部已用 `push_ready = rst_n && ...` 拦住，
   但适配层自己也不应该在复位期间驱动有效数据。
3. **在时钟沿采样 `in_ready`，不要在下降沿采样。**
   在下降沿采样会读到一个"看似还没被接受"的值，导致重复发送同一个事件。
4. **跨时钟域由适配层自己负责。** 多位信号（`in_note` 等）**不得**逐位打两拍同步 ——
   逐位同步会在多位同时翻转时产生中间态，得到从未存在过的音符编号。
   正确做法是整包用握手同步，或先在源端做跨域 FIFO。

## 5. 复位策略

`rst_n` 是**唯一**的清空手段，这是有意的设计选择，不是缺失功能：

- `interaction_top` **没有 flush 端口**。flush 有可能丢掉一条 release 事件，
  而丢 release = 卡音。队长的分配器没有 all-notes-off，一旦卡住只能靠复位解开。
- FIFO 内部在复位时清空 `mem`。这是为了让波形里没有 X 不定态，
  与 `voice_allocator.v` 里 `note_mem` 的清零写法一致。
- `push_ready` 上的 `rst_n` 门控是**承重设计**，清理代码时不要删：
  没有它，复位期间若发生 push，Verilog 对 `mem[wptr]` 的"后写覆盖"会让这个数据
  熬过清零循环，在复位结束后作为一条**陈旧事件复活**。

## 6. 遥测信号的语义

| 信号 | 含义 | 注意 |
|---|---|---|
| `fifo_level` | 当前排队事件数 | 纯可见性 |
| `fifo_full` | 队列满，`in_ready` 已拉低 | 生产阻塞中 |
| `throttle_level` | `in_valid && !in_ready` | **是多周期电平，不是脉冲** |
| `throttle_pulse` | 停顿段的起始，每段一个周期 | 要计"停顿次数"用这个 |
| `throttle_count` | 累计停顿段数 | **每段一次，不是每周期一次** |
| `pushed_count` | 累计被接受的事件数 | |
| `event_count` | 累计被取走的事件数 | |

`throttle_level` 是本模块最容易用错的地方：因为握手要求 `valid` 一直保持到 `ready`，
这个信号在一次停顿里会**持续约 66 个周期**。把它直接接进累加器，读数会虚高约 66 倍
（实测：32 次停顿 = 2080 个停顿周期）。要计停顿次数请用 `throttle_pulse` 或 `throttle_count`。

停顿时长则恰好相反 —— `throttle_pulse` 每段只有 1 个周期，用它测时长会得到 32 而不是 2080。
**两个数各有各的用途，实测数字见 `docs/队员B-验证记录.md`。**

### 守恒恒等式（可在板级外部校验，不需要逻辑分析仪）

```text
pushed_count == event_count + fifo_level
```

任何时候都成立（计数器饱和前）。这条恒等式让"静默丢了一条 release"（= 卡音）
可以被**从外部**检出，而不只是靠仿真断言。若 `fifo_level == 0` 且两个计数器相等，
说明队列确实排空了。两个计数器都保留、而不是只留一个，就是为了这条恒等式。

## 7. 集成 diff（方案 A：队长顶层吸收 FIFO）

> **本节是提案，不是已实施的改动。** 队长文件本轮零改动。

在 `rtl/captain_system_top.v` 中：

**第一步，端口改名**（`event_*` 输入 → `in_*`）：

```diff
-    input wire event_valid,
-    output wire event_ready,
-    input wire event_on,
-    input wire [6:0] event_note,
-    input wire [6:0] event_velocity,
-    input wire [1:0] event_timbre,
+    input wire in_valid,
+    output wire in_ready,
+    input wire in_on,
+    input wire [6:0] in_note,
+    input wire [6:0] in_velocity,
+    input wire [1:0] in_timbre,
```

**第二步，新增遥测输出端口**：

```diff
+    output wire [5:0] input_fifo_level,
+    output wire input_fifo_full,
+    output wire throttle_level,
+    output wire throttle_pulse,
+    output wire [31:0] throttle_count,
+    output wire [31:0] pushed_count,
+    output wire [31:0] event_count,
```

**命名冲突警告**：`captain_system_top.v` 第 39 行**已经有一个 `fifo_level`**，
是 `[1:0]` 的 I2S 采样 FIFO 水位。我方的水位必须叫 `input_fifo_level`，
否则会静默接错 —— 两个信号宽度不同（6 位 vs 2 位），Verilog 会截断而不是报错。

**第三步，实例化并接线**：

```diff
+    wire event_valid, event_ready, event_on;
+    wire [6:0] event_note, event_velocity;
+    wire [1:0] event_timbre;
+
+    interaction_top #(.DEPTH(32), .AWIDTH(5)) u_inputs (
+        .clk(clk), .rst_n(rst_n),
+        .in_valid(in_valid), .in_ready(in_ready), .in_on(in_on),
+        .in_note(in_note), .in_velocity(in_velocity), .in_timbre(in_timbre),
+        .event_valid(event_valid), .event_ready(event_ready), .event_on(event_on),
+        .event_note(event_note), .event_velocity(event_velocity),
+        .event_timbre(event_timbre),
+        .fifo_level(input_fifo_level), .fifo_full(input_fifo_full),
+        .throttle_level(throttle_level), .throttle_pulse(throttle_pulse),
+        .throttle_count(throttle_count),
+        .pushed_count(pushed_count), .event_count(event_count)
+    );
```

`u_control` 的实例化**一个字都不用改** —— 它看到的仍然是同样名字、同样宽度的 `event_*`。

### 方案 A 的连带影响

| 受影响文件 | 影响 | 处理 |
|---|---|---|
| `rtl/captain_control_top.v` | 无 | 不动 |
| `rtl/voice_allocator.v` | 无 | 不动 |
| `rtl/i2s_tx.v` | 无 | 不动 |
| `sim/tb_i2s_tx.sv` | **会编译失败** | 它 `dut` 实例化 `captain_system_top` 并驱动 `.event_valid`，改名后这些连接不再存在 |
| `sim/tb_voice_allocator.sv` | 无 | 它测的是 `captain_control_top` |

`tb_i2s_tx.sv` 的修法很小：把 30–40 行的 `.event_valid/.event_ready/.event_on/...`
六个连接改名为 `.in_*`，`send_event` 任务体不动。但它**改变了这个测试台的性质**：
原来它直接驱动分配器，改名后它驱动的是 FIFO 输入，中间隔了一层队列。
`send_event` 里"发一个脉冲"的写法在隔着 FIFO 之后语义会变，需要改成守握手的写法，
否则这个回归测试会开始失败 —— 而失败的原因是测试台写法，不是设计缺陷。

## 8. 集成 diff（方案 B：B 侧包装，队长文件零改动）

若队长希望 `captain_system_top.v` 与 `tb_i2s_tx.sv` **完全不动**，可由我方提供一个包装模块：

```verilog
module synth_with_inputs #(parameter integer BCLK_HALF_DIV = 8) (
    input wire clk, rst_n,
    input wire in_valid, output wire in_ready,
    input wire in_on, input wire [6:0] in_note,
    input wire [6:0] in_velocity, input wire [1:0] in_timbre,
    /* 其余端口原样透传 */
);
    wire event_valid, event_ready, event_on;
    wire [6:0] event_note, event_velocity;
    wire [1:0] event_timbre;

    interaction_top #(.DEPTH(32), .AWIDTH(5)) u_inputs ( ... );   // 接线同方案 A 第三步

    captain_system_top #(.BCLK_HALF_DIV(BCLK_HALF_DIV)) u_synth (
        .clk(clk), .rst_n(rst_n),
        .event_valid(event_valid), .event_ready(event_ready), .event_on(event_on),
        .event_note(event_note), .event_velocity(event_velocity),
        .event_timbre(event_timbre),
        /* 其余端口原样透传 */
    );
endmodule
```

| | 方案 A | 方案 B |
|---|---|---|
| 队长 RTL 改动 | 顶层增删端口 | **零** |
| `tb_i2s_tx.sv` | 需改名连接，且 `send_event` 要改写 | **零** |
| 顶层数量 | 1 个 | 2 个（板级顶层变成新包装） |
| 职责归属 | 队长维护集成顶层 | 契合"队长维护集成顶层，B 交付边界模块" |

**建议方案 B**：它把"集成"变成一次纯新增，两个既有测试台都保持原样继续有效
（`tb_i2s_tx` 仍然是 `captain_system_top` 的有效单元测试，只不过不再是最顶层了）。
若队长更希望只有一个顶层，方案 A 也完全可行，只是要连带改 `tb_i2s_tx.sv`。

## 9. 和弦展开的语义（需要队长确认）

文档只写了"和弦展开为多条音符事件"，没有写明由谁展开。我采用**保守读法**：

> **一次 push = 一条音符事件。和弦 = N 次顺序 push。**
> FIFO 保证这 N 条每条恰好一次、顺序不变。

我没有实现"一个手势自动展开成和弦"。理由：那需要知道按键映射表、和弦定义、
以及"哪些音符属于同一个手势"，这些都不在本轮已知信息内，且属于另一个模块。

**若队长期望的是自动展开**，那需要另行约定模块文件名与接口（输入是"手势 + 根音 + 和弦类型"，
输出是 N 条事件），我可以下一轮做。

## 10. DEPTH 的论证（实测，非估算）

在 GW5AT-60B 上用 GOWIN V1.9.12.03 单独综合 `interaction_top` 的实测结果：

| DEPTH | 整模块寄存器 | 整模块 LUT |
|---|---|---|
| 8 | 243 | 136 |
| 16 | 382 | 223 |
| **32（默认）** | **657** | **377** |

`u_interaction` 自身（不含 FIFO）恒为 97 寄存器 / 93 ALU / 44 LUT。

**为什么默认选 32**：一次 16 音和弦是两条事件（按下、松开）各 16 条，共 32 条。
队列至少要能装下一整个和弦的按下突发，否则生产者会在和弦中途被反压 —— 虽然不会丢事件
（反压是安全的），但会把手势的时序拉长。32 恰好等于"16 音和弦的按下"这一最坏突发的长度，
且是 2 的幂（`AWIDTH=5` 可由 `DEPTH` 直接推出）。

**若认为 657 寄存器偏多**：这是可以调的，`DEPTH` 是唯一的调节旋钮 —— 改成 16 省 275 个寄存器。
但注意**把 `mem` 改写成可推断 RAM 的写法得不到任何收益**，这一点已经实测证伪并写在
`rtl/event_fifo.v` 的注释里：搬到仅有时钟的块后仍然是 657 个寄存器，
真正阻止 RAM 推断的是**异步复位分支**，不是清零循环。
所以不要在这条路上花时间，要么接受这个数，要么改 `DEPTH`。

阶段 02 整机基线是 843 寄存器 / 50 ALU / 858 LUT，接入后预计约 1500 寄存器 / 143 ALU / 1235 LUT
—— **这个"预计"是估算，不是实测**，以队长接入后重跑综合的数字为准。

## 11. 尚未完成 / 待办

- **真实传感器驱动**：无型号、无引脚、无电平标准、无去抖参数，故本轮只定义抽象输入接口
  与适配层契约（第 4 节），不实现具体驱动。
- **与队长真实 RTL 的联合仿真**：本轮集成测试用的是按公开契约建模的分配器模型
  （`BUSY=66` 计数器 + `done_valid` 抢占注入），**没有编译队长的 `voice_allocator`**。
  联合仿真是集成步骤，属队长职责。
- **上板**：布局布线、时序收敛、CST/SDC、端到端延迟均未验证。

## 12. 需要队长确认的两件事

1. **和弦展开语义** —— 见第 9 节。我实现的是"一次 push 一条事件"，是否与你的预期一致？
2. **集成方案选 A 还是 B** —— 见第 7、8 节。方案 B 对你零改动，我建议 B；
   若选 A，请注意 `fifo_level` 的命名冲突和 `tb_i2s_tx.sv` 的连带修改。
