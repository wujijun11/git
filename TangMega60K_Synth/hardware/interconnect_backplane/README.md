# Tang Mega 60K 外设转接底板（便捷接线版）

这块板的目标是把现有模块插上就能接好，减少杜邦线和查表次数。它是被动转接/分配板：不改变 FPGA、C3、MPR121、74AHCT125 的协议，不替代 FPGA 底板，也不把 5V 送入 FPGA GPIO。

## 连接方式

- J_FPGA_J13：2×20、2.54 mm 母座，直接对接 Tang Mega 60K 底板 J13。
- J_PWR_3V3：2P 2.54 mm，接 FPGA J9 的 3.3V 与 GND；板上分配给三块 MPR121。
- J_MPR1、J_MPR2、J_MPR3：每个 1×6，丝印顺序均为 3V3 / GND / ADD / SCL / SDA / IRQ。
- J_C3：1×3，丝印顺序为 TX7 / RX6 / GND；板上已经交叉到 FPGA UART，C3 不需要再查 J13 脚号。
- J_AHCT：1×3，丝印顺序为 DATA / GND / 5V_AUX；DATA 来自 FPGA J13-14，5V_AUX 只给 AHCT/灯板侧。
- J_LED_PWR：2P 螺丝端子，接外部稳压 5V，仅给 AHCT125 和 WS2812 灯板。该 5V 与 C3/FPGA 的逻辑供电隔离，只通过 GND 共地。

## 已固定的网络

| 网络 | FPGA J13 | 底板接口 |
| --- | ---: | --- |
| MPR1_SCL | 1 | J_MPR1.4 |
| MPR1_SDA | 2 | J_MPR1.5 |
| MPR2_SCL | 3 | J_MPR2.4 |
| MPR2_SDA | 4 | J_MPR2.5 |
| MPR3_SCL | 5 | J_MPR3.4 |
| MPR3_SDA | 6 | J_MPR3.5 |
| C3_TX7_TO_FPGA_RX | 7 | J_C3.1 |
| C3_RX6_FROM_FPGA_TX | 8 | J_C3.2 |
| MPR1_IRQ | 9 | J_MPR1.6 |
| MPR2_IRQ | 10 | J_MPR2.6 |
| J13_11_5V | 11 | **不接 / NC** |
| GND | 12 | J_C3.3、J_MPR*.2、J_AHCT.2、J_PWR_3V3.2 |
| MPR3_IRQ | 13 | J_MPR3.6 |
| LED_DATA_3V3 | 14 | J_AHCT.1 |

J_MPR*.3 ADD 全部接公共 GND，使三个独立总线都使用 MPR121 地址 0x5A。三组 SCL/SDA 不能在底板上短接。

## 电源和安全边界

1. 三块 MPR121 共用一组 3.3V；J_PWR_3V3 只接 FPGA J9 已确认的 3.3V/GND，不从 J13-11 取电。
2. J_LED_PWR 的 5V 只去 AHCT125 和 WS2812 灯板；不能接 J13 的逻辑电源或 C3 供电脚。
3. J13-11 在底板上保留 NC 焊盘/丝印，避免把 5V 误插到外设。
4. 每个 MPR 接口旁标出 3V3 和 GND，C3 接口旁标出 TX7/RX6，AHCT 接口旁标出 DATA/GND/5V_AUX。
5. 首板需要做断电导通检查，再分别测 J_PWR_3V3 和 J_LED_PWR；不要把两个电源端子并接。

## 建议机械规格

- 2 层 FR-4，1.6 mm，1 oz，建议 100 mm × 60 mm 起步。
- FPGA J13 母座放在底板一侧，MPR/C3/AHCT 接口全部朝外，避免插上后遮挡 FPGA 散热器。
- MPR 接口用不同颜色丝印：MPR1 红、MPR2 绿、MPR3 蓝；C3 标 BLE UART；AHCT 标 LED LEVEL。
- J13、J_PWR_3V3、J_LED_PWR 使用防呆丝印和 1 脚方形焊盘。若要真正防反插，需要改用带防呆的连接器，不能只依赖丝印。

本目录的 connector_map.csv、backplane_spec.json 和 layout_preview.svg 是第一版接口定义与布局草图。它们已经按当前工程引脚表生成，但**还不是可直接下单的 Gerber**；在生成生产文件前仍需确认 J13/J9 的实物连接器方向、C3 模块安装方向、底板外形和安装孔位置，并在嘉立创EDA中完成原生 DRC、BOM/CPL 与 Gerber 检查。
