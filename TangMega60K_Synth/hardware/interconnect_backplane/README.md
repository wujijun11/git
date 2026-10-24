# Tang Mega 60K 外设转接底板（便捷接线版）

这块板的目标是通过集中接口和固定线束减少杜邦线和查表次数。它是被动转接/分配板：不改变 FPGA、C3、MPR121、74AHCT125 的协议，不替代 FPGA 底板，也不把 5V 送入 FPGA GPIO。

**当前是 R0.1 接口草案，尚不可下单。** 本轮将 AHCT 接口修正为与现有板一致的独立 2P 信号接口和 2P 电源接口，并补全 J13 未使用脚的 NC 定义。MPR 的 1×6 是底板侧逻辑线束顺序，尚不能作为模块直插母座针序；C3 的 GPIO7、GPIO6、GND 也不是模块上连续的三针。后续要做成便捷插接，需要根据原板丝印、安装方向和尺寸定下模块母座或成套线束。

## 连接方式

- J_FPGA_J13：2×20、2.54 mm 母座，计划对接 Tang Mega 60K 底板 J13；pin1 视角、母座安装面和散热器避让尚待实物核实。
- J_PWR_3V3：2P 2.54 mm，接 FPGA J9 的 3.3V 与 GND；板上分配给三块 MPR121。
- J_MPR1、J_MPR2、J_MPR3：每个 1×6，底板侧逻辑顺序均为 3V3 / GND / ADD / SCL / SDA / IRQ。此顺序尚未与模块原排针逐脚核实；不能按它直接整排插模块。
- J_C3：1×3 线束接口，丝印顺序为 TX7 / RX6 / GND；分别接 C3 的 GPIO7、GPIO6、GND，网络表将 TX/RX 交叉到 FPGA。它不是 C3 整板直插插座。
- J_AHCT：1×2，顺序为 DATA / GND；接现有 AHCT125-LED-R1 的 J1-1 IN / J1-2 GND。此接口不带 5V。
- J_AHCT_PWR：2P 螺丝端子，顺序为 +5V_AUX / GND；单独接现有 AHCT 板 J3 的 +5V / GND。
- J_LED_PWR：2P 螺丝端子，接外部稳压 5V，仅送至 J_AHCT_PWR，再由 AHCT 板现有 J2 给灯板供电。5V 网络不与 FPGA/C3 的正电源相连，GND 共地。

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

J_MPR*.3 ADD 全部接公共 GND，使三个独立总线都使用 MPR121 地址 0x5A。三组 SCL/SDA 不能在底板上短接。J13 第15～40脚在本转接板上全部保留不接；它们在 FPGA 底板上原有的信号/供电属性不改变。

## 电源和安全边界

1. 三块 MPR121 共用一组 3.3V；J_PWR_3V3 只接 FPGA J9 已确认的 3.3V/GND，不从 J13-11 取电。
2. J_LED_PWR 的 5V 只去 AHCT125 和 WS2812 灯板；不能接 J13 的逻辑电源或 C3 供电脚。
3. J13-11 在底板上保留 NC 焊盘/丝印，避免把 5V 误插到外设。
4. 每个 MPR 接口旁标出 3V3 和 GND，C3 接口旁标出 TX7/RX6，AHCT 信号接口标出 DATA/GND，独立电源端子标出 +5V/GND。
5. 首板需要做断电导通检查，再分别测 J_PWR_3V3 和 J_LED_PWR；不要把两个电源端子并接。

## 建议机械规格

- 2 层 FR-4，1.6 mm，1 oz，建议 100 mm × 60 mm 起步。
- FPGA J13 母座放在底板一侧，MPR/C3/AHCT 接口全部朝外，避免插上后遮挡 FPGA 散热器。
- MPR 接口分别标 MPR1、MPR2、MPR3；普通单色丝印用文字和边框分区。预览图中的红、绿、蓝仅用于辅助识别，不是生产多色丝印要求。
- J13、J_PWR_3V3、J_LED_PWR 使用防呆丝印和 1 脚方形焊盘。若要真正防反插，需要改用带防呆的连接器，不能只依赖丝印。

本目录的 connector_map.csv、backplane_spec.json 和 layout_preview.svg 是接口定义与连接示意。它们按当前工程引脚表生成，但**还不是可直接下单的 Gerber**。原生生产工程仍需确认 J13/J9 的实物连接器方向、MPR 原排针顺序、C3 模块安装方式、底板外形和安装孔位置，并在嘉立创EDA中完成 DRC、BOM/CPL 与 Gerber 检查。

此前生成的照片标注说明记载过不同的 MPR 排针顺序；AI 标注图本身不能作为封装生产依据。这里保留待核实状态，不将任意一种顺序当成已确认的模块直插针序。

## 交给嘉立创EDA前的文件

- `bom.csv`：只列被动转接板所需的连接器和安装孔，不把 FPGA、C3、MPR121 或 AHCT125 重复做进板上。
- `connector_map.csv`：逐针网络表，适合录入原理图网络标签。
- `validate_backplane.py`：检查重复脚号、CSV 与 JSON 一致性、J13 全部40脚的使用/NC状态、串口两端网络、三路 MPR 网络及独立 AHCT 电源边界：

  ```text
  python validate_backplane.py
  ```

通过这个检查只代表接口定义的电气一致性；脚本同时明确输出机械/插接未核实状态。它不替代原生 PCB DRC、实物针序和首板验收。

`interconnect_backplane_r0.zip` 保留交付包文件名，更新内容的版本以包内 `backplane_spec.json` 为准。包中不包含未完成的 EDA 工作副本。
