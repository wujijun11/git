# 队员B（事件FIFO与输入交互）验证记录

验证日期：2026-09-15。

本轮交付 `rtl/event_fifo.v` 与 `rtl/interaction_top.v`。所有数字均为本机实测，
下文凡属推算的一律标注"估算"，不与实测混列。

## 仿真：ModelSim Intel FPGA Edition 10.5b

独立测试台 `sim/tb_interaction.sv`，脚本 `sim/run_interaction.do`。

| 检查 | 结果 | 证据 |
|---|---|---|
| 编译 | 0 errors、0 warnings | sim/test_interaction_results.log |
| FIFO 用例 F1–F12 @ DEPTH=2 | 通过 | 同上 |
| FIFO 用例 F1–F12 @ DEPTH=32 | 通过 | 同上 |
| 集成用例 I1–I9 @ DEPTH=32 | 通过 | 同上 |
| 完成标志 | `ALL INTERACTION TESTS PASSED` | 同上 |

实测的完成行（Transcript 原文）：

```text
FIFO CASE PASSED DEPTH=2 pushed=8084 delivered=8084 full_exchange=40 peak_level=2
FIFO CASE PASSED DEPTH=32 pushed=10096 delivered=10096 full_exchange=40 peak_level=32
INTERACTION CASE PASSED DEPTH=32 pushed=36 delivered=36 throttle_count=+32 over 32 episodes (2080 stalled cycles)
ALL INTERACTION TESTS PASSED
```

这四行数字的含义，以及它们各自能证明什么、不能证明什么：

| 数字 | 含义 | 证明了什么 |
|---|---|---|
| `DEPTH=2 pushed=8084 delivered=8084` | 全部 8084 次推入都原样弹出 | 无丢事件、无重复事件 |
| `DEPTH=2 peak_level=2` | 浸泡过程真的填满过深度 2 的队列 | 这个用例不是"没碰到边界就跑完了" |
| `DEPTH=32 peak_level=32` | 同上，深度 32 也真的满过 | 满态路径被真实执行 |
| `full_exchange=40` | 满态下同拍 push+pop 成功 40 次 | 与队长 `tb_i2s_tx` 的 `full_exchange=40` 同样强度 |
| `pushed=36 delivered=36` | 16 音和弦 + 恢复 + 16 音释放全序送达 | 事件一条不差、顺序不乱 |
| `throttle_count=+32 over 32 episodes` | 32 次停顿只计 32 次 | 计数器按"停顿段"计，**不是**按停顿周期计 |

最后一行是本模块最容易写错的地方。同一行里 `2080 stalled cycles` 与 `+32` 并存：
`in_valid && !in_ready` 是一个**多周期电平**（队长分配器收一个事件要 ~66 周期），
若把它直接接计数器，会得到 2080 而不是 32。测试台同时断言了两件事：

- `throttle_count - c0 !== stall_episodes` → 失败即"按周期计"；
- `throttle_count - c0 > stall_cycles / 4` → 失败即"电平与脉冲被混为一谈"。

两条断言都在 `+32` 上精确通过，所以"每停顿段一次"是被证伪式地测过的，
不是看波形推断的。

测试台采样边沿：DUT 在 `posedge clk` 递增，测试台参考计数器也在 `posedge clk` 递增。
早期版本在 `negedge` 采样，得到 `moved 32 times over 33 episodes` —— 半个周期的采样偏斜。
这个偏斜不是被测设计的缺陷，改成同沿后精确相等。**若日后有人把测试台的采样边沿改回
下降沿，这个断言会重新报 33 而不是 32。**

## 仿真：接入团队回归

`scripts/test.ps1` 的 `$testCases` 追加一行后，三个测试依次运行：

| 测试 | 日志 | 标志 | 结果 |
|---|---|---|---|
| 控制器 | sim/test_results.log | `ALL TESTS PASSED` | 通过 |
| I2S | sim/test_i2s_results.log | `ALL I2S TESTS PASSED` | 通过 |
| 交互 | sim/test_interaction_results.log | `ALL INTERACTION TESTS PASSED` | 通过 |

三个日志均为 0 errors / 0 warnings，脚本退出码 0。

注：`scripts/test.ps1` 的默认 `$ModelSimBin` 是队长机器上的 `C:\msim\...`。
在本机运行需显式指定：

```powershell
./scripts/test.ps1 -ModelSimBin 'D:\Quartus-lite-18.1.0.625-windows\modelsim_ase\win32aloem'
```

这一行为在接入 CI 前就已存在，不是本次改动引入的。

## 综合：GOWIN V1.9.12.03

目标器件 GW5AT-60B / GW5AT-LV60PG484AC1/I0，工程 `TangMega60K_Synth.gprj`。
全部综合在**仓库以外的临时副本**中进行，未污染团队工程目录。

### 第 1 步：我方文件不破坏既有构建

把我的两个文件加进 `.gprj` 后重跑队长的综合：

| 指标 | 加我方文件前 | 加我方文件后 |
|---|---|---|
| 寄存器 | 843 | **843(0)** |
| ALU | 50 | **50(0)** |
| LUT | 858 | **858(0)** |

三者逐位一致，无新增错误。原因不是"我的模块很省"，而是
**GOWIN 剪枝了未被实例化的模块** —— `captain_system_top` 里还没有 `interaction_top`。
所以这张表能证明"我的追加是无害的"，**不能**证明"我的模块占 0 资源"。

### 第 2 步：我方模块的真实资源

为绕开剪枝，另建一个仅用于综合的临时顶层（实例化 `interaction_top` 并引出全部端口，
**该文件不提交**）以取得真实数字。同一流程在 `DEPTH=8/16/32` 下各跑一次：

| DEPTH | u_events 寄存器 | u_events LUT | 整模块寄存器 | 整模块 LUT |
|---|---|---|---|---|
| 8 | 146 | 92 | 243 | 136 |
| 16 | 285 | 181 | 382 | 223 |
| 32（默认） | 560 | 333 | **657** | **377** |

`u_interaction` 自身（不含 FIFO）在三种深度下恒为 **97 寄存器 / 93 ALU / 44 LUT**。
校验：560 + 97 = 657，333 + 44 = 377，与上表一致。

**口径说明**：这是模块**单独综合**的数字，不等于集成进整机后的最终占用；
但 `interaction_top` 目前未被顶层实例化，单独综合是本轮唯一能取得真实数字的方式。
集成后的数字需由队长在接入后重跑综合给出。

### 第 3 步：一次被证伪的优化尝试

模块头注释早期的说法是"`mem` 的清零让数组无法映射为 RAM，代价是面积；若嫌大可减小 DEPTH"。
这是一个**没有测过就写下的推断**。为确认它，做了对照实验：

| 变体 | 网表结果 |
|---|---|
| 原版（`mem` 在带复位的块内 + 清零） | 657 个 `DFFCE`，无 RAM |
| `mem` 移入仅有时钟的块（期望推断出 RAM） | 2482 个 `RAMOUT` 信号 + 544 `DFFRE` + 113 `DFFCE` |

第二行相加仍是 **657 个寄存器**。结论：搬迁 `mem` 得不到任何收益，
**真正阻止 RAM 推断的是异步复位分支**，不是清零循环。该结论已写回 `rtl/event_fifo.v`
的注释，替换掉原来那段错误的推断。

另外三次相同结果的复核：曾怀疑 GOWIN 缓存了结果，比对网表后确认综合确实重新执行，
三次结果确实逐位相同，不是缓存。

## 尚未验证

- 布局布线、时序收敛、实际最高工作频率。
- 板级时钟与复位、CST/SDC 引脚约束。
- 真实传感器：无型号、无引脚、无电平标准、无去抖参数，故只定义抽象输入接口与适配层契约。
- 端到端演奏延迟（需整机集成后实测）。
- 与队长真实的 `voice_allocator` 联合仿真：本轮集成测试用的是按公开契约建模的分配器模型
  （`BUSY=66` 计数器 + `done_valid` 抢占注入），**不是**编译队长的 RTL。
  联合仿真是集成步骤，属队长职责范围，见 `docs/队员B-集成说明.md` 的集成 diff。
