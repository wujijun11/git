# 25灯点阵与微雪ESP32-C3适配（2026-10-13）

**2026-10-27状态：5×5灯板/灯座尚未进行实物测试。**下列灯色、映射和功能是设计及仿真说明，供电、电平转换、DIN方向、灯序和逐键指引/学习均待验收，不表示已经点亮或通过整机实测。

本次选型是5V、25颗WS2812B的5×5灯板，以及微雪ESP32-C3-Zero / Zero-M。约39mm的灯板作为独立曲谱/触摸提示面板；不会自动把灯安装到整条25键琴键上。主音源、曲谱计时和LED串行输出仍由FPGA完成，C3只转发手机BLE控制包，不承担音频合成，也没有加入预录音播放。

## 灯的含义和默认配置

- 绿色：曲谱当前要求按下的键，包括KEY0曲谱播放、KEY1静音引导。
- 蓝色：MPR121已检测到的实体琴键触摸。
- 青色：同一键既是曲谱目标，也正在被触摸。这是状态重叠，不代表节奏/力度评分已实现。
- 全灭：没有曲谱目标和实体触摸。普通上电不自动亮满白，也不自动开始灯序自检。

绿色默认32/255，蓝色16/255；驱动每通道硬上限32/255，组合时红色保持0。这只是数字亮度限制，不是供电限流装置。输出为25颗×24位GRB，约750µs数据加300µs锁存，约1.05ms一帧；实际49.152MHz量化后约1.057ms。guide和touch在同一帧开始时一起拍快照，帧内不会被输入变化撕裂。

`rtl/board/board_contest_full_top.v`的`GUIDE_PIXEL_KEY_MAP`是125位常量，每个物理灯号占5位；最右侧字段属于DIN后第一颗灯。默认按串行链顺序映射逻辑键0..24，保留旧版行为。它**不承诺卖家灯板是逐行、蛇形、哪个角为第一颗**，照片不能证明内部链序。支持1..25颗，超出范围或非法/重复映射会在仿真中报错。

## 到货后校准灯号

1. 先确认灯板`DIN / 5V / GND`丝印和3P实际线序。截图的红/黑/黄标注可作参考，不能只凭外壳方向插接。
2. 接线并上传`calibration-25.json`到现有手机App，选择用户曲谱，点击“启动LED引导”。它只含50条按键事件：逐键亮800ms、间隔200ms，不含音频文件。使用静音引导即可检查25颗灯，避免同时发声干扰。
3. 按0..24顺序记录亮灯位置；不需要改变默认程序就能先给每个亮点贴对应键号。逻辑键0..24默认对应MIDI60..84（C4..C6）。
4. 若希望面板从左上向右逐行编号，填写`pixel,key` CSV：pixel是DIN链序，key是希望该位置对应的琴键号。运行`python scripts/configure-led25.py --map <CSV路径>`生成参数；复制到顶层的`GUIDE_PIXEL_KEY_MAP`默认值，然后重新仿真、构建、下载。不要仅修改琴键MIDI映射来补偿灯板空间方向。

已确认蛇形走线、左上起点的面板可用`python scripts/configure-led25.py --layout serpentine`；倒装可加`--rotate180`。这两个选项是校准后的配置模板，不是对商品走线的推断。

## 连接边界

灯板红色5V与黑色GND接独立稳压5V电源；黑色同时与FPGA GND共地。数据由主工程`guide_led_data`输出，经5V供电的74AHCT125单向缓冲后，串330Ω电阻接灯板DIN。不要让5V进入FPGA GPIO，不要将3P整体套到三根相邻GPIO上。灯板电源入口可接500～1000µF、耐压至少6.3V电容，AHCT电源近端加0.1µF去耦；具体模块按丝印核对VCC、GND、A、Y及低有效OE。

约定的FPGA封装球位仍是LED A15、UART RX A14 / TX A13；本次没有改动约束或自动下载。用户照片确认底板版本为31005；2026-10-17已沿60K核心BTB与31005底板BTB核对，LED对应J13-14，UART RX/TX对应J13-7/8，完整表见[整机连线方案](../../docs/整机连线方案-20261017.md)。现场仍须确认连接器与pin1方向、供电电压和导通，原理图映射不等于实物验收。MPR121继续使用3.3V接口。

微雪C3板使用专用`waveshare_esp32_c3_zero`编译目标、4MB Flash及原生USB CDC。C3 GPIO7(TX)接FPGA UART RX，GPIO6(RX)接FPGA UART TX，双方GND共地，均为3.3V信号。C3可先USB独立供电；不要同时随意并接两个5V电源。Zero-M为焊排针版本，裸Zero需要先焊排针才能可靠接杜邦线。原理、固件、状态灯和烧录说明见[蓝牙桥说明](../../firmware/ble_bridge/README.md)。

## 软件验证与实物边界

`scripts/test-performance.ps1`验证既有曲谱、板载动作和WS2812真实时钟协议；`scripts/test-ws2812-matrix.ps1`从外部波形解码全部25灯，覆盖逐灯、蛇形、旋转、颜色、亮度截断、快照、复位及非法参数；`scripts/test-full-system.ps1`验证整机控制/音源集成与紧急静音。新位流的时序、资源和哈希见`verification/contest-full-matrix-c3-20261013`。测试通过并不表示真实BLE链路、灯序、供电或整机延迟已经验收。

官方参考：[WS2812B-V5/W时序](https://datasheet.lcsc.com/datasheet/pdf/3795cfb9d54f7ec8ecc0b043ede3c05a.pdf?productCode=C2846931)、[TI AHCT125](https://www.ti.com/product/SN74AHCT125)、[NeoPixel安装建议](https://learn.adafruit.com/adafruit-neopixel-uberguide/best-practices)、[微雪C3-Zero资料](https://www.waveshare.net/wiki/ESP32-C3-Zero)。商品实际LED批次、接插件线序和灯号仍以到货实物为准。
