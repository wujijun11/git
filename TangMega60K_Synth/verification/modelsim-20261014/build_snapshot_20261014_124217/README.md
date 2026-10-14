# Watchdog 修复后的完整综合与时序复核

最终源码构建使用本机 Gowin V1.9.12（64位）`gw_sh.exe`，目标为
`board_contest_full_top` / `GW5AT-LV60PG484AC1/I0`。最终一轮从
2026-10-14 12:56:09 运行至 13:07:56（UTC+8），退出码为 **0**，
日志含 `FULL BUILD TIMING PASS`。

| 指标 | 2026-10-13 基线 | 本次最终构建 | 变化 |
|---|---:|---:|---:|
| Setup 最小裕量 | 0.039 ns | 0.051 ns | +0.012 ns |
| Hold 最小裕量 | 0.022 ns | 0.065 ns | +0.043 ns |
| Recovery 最小裕量 | 7.369 ns | 6.957 ns | -0.412 ns |
| Removal 最小裕量 | 0.535 ns | 0.669 ns | +0.134 ns |
| Setup 违规端点 | 0 | 0 | 0 |
| Hold 违规端点 | 0 | 0 | 0 |
| BSRAM | 106/118 | 106/118 | 0 |
| Logic | 21986/59904 | 22346/59904 | +360 |
| Register | 15322/60780 | 15322/60780 | 0 |
| DSP | 50.5/118 | 50.5/118 | 0 |

最差 setup 路径为
`system/sensors/eventizer/fifo_fifo_0_0_s/DO[14]` →
`system/watchdog/scan_2_s1/CE`，23级逻辑，仍仅剩 **51 ps** 裕量。
本次通过既有约束的布局布线检查，余量仍然紧张。

快照按 GPRJ 解析复制68项依赖，另保留完整 RTL、音频 ROM、视觉系数与
原构建 Tcl；80份输入在最终检查时与当前项目 SHA256 全部匹配。
最终源码包含两份板级文件的变量声明顺序兼容修正。
原项目 `full/impl` 的25个文件全部保持 SHA256 一致，文件集合没有新增或缺失。
本次没有修改综合参数、约束或音量，没有写入 FPGA。

首轮采用原板级声明顺序，其构建产物及日志保存在
`runs/initial_decl_order/`。随后同步两份声明修正并完整重跑；最终两轮
时序与资源数值相同。根目录的报告对应第二轮最终源码。

审查入口：

- `build-results.json`：最终资源、四类最小裕量、违规数、基线比较、产物哈希及保护检查。
- `gowin-build.log`、`gowin-build.exit.txt`、`gowin-run.json`：实际工具输出、退出码与时间。
- `full/impl/pnr/ContestFull.tr`、`ContestFull.rpt.txt`：原始时序与资源报告。
- `full/impl/pnr/ContestFull.fs`：本次新生成、未下载的位流。
- `snapshot-inputs.json`、`gprj-dependencies.json`：输入文件与依赖哈希。
- `protected-impl-before.json`、`protected-impl-after.json`：原实现目录保护证据。
- `analyze_build.py`：独立截断四个时序表，防止 Removal 混入后续脉宽表。

Setup/Hold 使用工具报告的总违规数；Recovery/Removal 没有独立总计数，
本记录报告其最小裕量。以上是数字实现证据，不代表新增硬件验收。
