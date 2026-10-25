# R2 原生 DRC 记录

嘉立创 EDA 原生 PCB DRC 已完成两次验证：布线修复后一次，以及重新打开并保存工程后一次。

- 最终线段：506
- 最终过孔：56
- Clearance Error：0
- Connection Error：0
- 最终证据：`../evidence/r2-drc-final-reopen.json`
- 工程：`TangMega60K-Backplane-R2-SameSide.eprj3`

下单前在嘉立创预览页确认以下项目：

1. 板框尺寸 190 mm × 50 mm，四个安装孔位置符合机械尺寸。
2. J1 的 40P 方向与 FPGA J13 的 1 脚方向一致。
3. J3/J4/J5 为 MPR121 接口，顺序为 `3V3 / GND / ADD / SCL / SDA / IRQ`；ADD 已接地，地址为 0x5A。
4. J6 为 C3 接口，顺序为 `TX7 / RX6 / GND`；对应 FPGA 端 J13-7、J13-8、J13-12。
5. J7 为 AHCT 数据接口；J8 为 AHCT 5V 辅助电源；J9 为 LED 5V 辅助电源。

AHCT125 成品板保持原设计，不在本底板工程内修改。
