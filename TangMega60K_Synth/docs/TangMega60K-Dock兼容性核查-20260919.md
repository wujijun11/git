# Tang Mega 60K Dock 兼容性核查

日期：2026-09-19。检查对象：当前本地 `AudioEngine_V2.gprj`、其RTL与既有综合/仿真证据。

后续更新：用户已确认60K套餐包含Dock底板。用户最终选择仅保留24位标准I2S比赛方案，当前工程已移除PT8211模式。本文以下为最初核查快照；当前配置见[标准I2S恢复记录](恢复24位标准I2S-20260919.md)。实际PCB版本及板级时钟、引脚和时序仍待确认。

## 结论与范围

核心器件型号匹配，64声部音源可以继续用于Tang Mega 60K；当前工程尚未完成NEO Dock板级适配，不能直接烧录后从底板耳机口发声。

用户商品：<https://item.taobao.com/item.htm?id=811066493020&skuId=5771218226546>。本次淘宝正文读取失败，浏览器访问也未成功，未核实该SKU当前选项、附件或出货PCB版本。以下条件为“60K核心板 + TANG MEGA NEO Dock”，不适用于单独核心板、Tang Console或138K Pro底板。历史套餐照片不能证明本次SKU实际选中项。

## 工程与硬件对照

| 项目 | 证据与结果 |
|---|---|
| FPGA型号 | `AudioEngine_V2.gprj`选用`GW5AT-LV60PG484AC1/I0`、`GW5AT-60B`，与官方60K型号及B版本要求一致。 |
| 核心音源 | 64声部DDS/ADSR、混音及三维表情在FPGA RTL实现；64声部混合成左右两声道。9月19日I2S仿真通过。 |
| 综合资源 | 既有延迟顶层报告：2713 LUT、2002寄存器、34 BSRAM、3 MULTALU27X18、3 MULT27X36。报告位于工作区`tmp/teammate_a_review_20260917_213336/synth_fx_resources.xml`。这不是本次新跑的综合，也不是整机布局布线结果。 |
| 时钟 | 当前`i2s_tx`默认DIV=8，要求49.152 MHz系统时钟才能输出48 kHz采样、3.072 MHz BCLK。未找到板级PLL或时钟配置。不能把板卡现有时钟直接当作此频率。 |
| 板级顶层 | `rtl/audio/audio_system_v2.v`明确标注不是板级顶层；event/expr端口是内部模块接口，不能逐项直接分配到排针。 |
| 引脚、电平及时序 | 项目内没有CST或SDC，GPRJ也未引用这些文件。尚无确定引脚、BANK供电、输出延迟约束和布局布线验证。 |
| 板载音频 | 已保存的NEO Dock-60K 31004原理图Rev 1.4（2025-03-31）第10页：U16为PT8211-S，U20为NS4263。PT8211使用16位LSBJ/右对齐输入；当前发送器为24位Philips I2S、每声道32位槽，格式不能直接互换。 |
| 功放控制 | 同页标明PA_EN=1关闭、PA_EN=0开启；当前顶层没有此板级控制端口。实际使用前还需核对其引脚、上电静音和本机板版。 |
| 25键/传感器 | 当前音源接收内部事件，键床扫描、物理输入同步和前端事件生成尚未包含在本音频工程内。 |

## 输出路线

优先保留现有标准I2S发送器，按此前采购方案使用支持24位I2S的PCM5102A成品DAC，通过已核对的GPIO输出BCLK/LRCLK/DATA，并接有源音箱。这保留现有64声部音源和I2S验证路径，也与用户提供赛题“I2S输出到DAC”的文字要求直接一致。具体模块的供电、FMT、XSMT和SCK接法仍须依据模块原理图确定。TI说明PCM5102A支持通过内部PLL工作的三线I2S，无须因此立即新增外部MCLK器件。

如使用底板PT8211-S，应新增独立的16位LSBJ发送适配及对应自检，处理位宽缩减、WS极性、发送边沿、功放静音控制。不能仅改端口名字或把24位截成16位就认定兼容。该路线是否满足赛题对I2S的严格要求，需向赛方确认；本次不把它列为已经合规。

## 下一步验收顺序

1. 确认商品选项包含60K核心板和NEO Dock，取得实际底板版本丝印及相应原理图。
2. 固定音频输出路线，逐项建立FPGA球号、连接器脚号、BANK供电、复用冲突与方向表，再生成CST。
3. 确认板载参考时钟及音频时钟生成方案，补PLL/时钟配置、锁定后复位释放和启动静音。如改采样率，应同时更新DDS频率常量。
4. 新增板级顶层，内部实例化`audio_system_v2`，接入可综合的演奏事件源；补SDC并完成布局布线及时序检查。
5. 上板先验证时钟和单音，再验证和弦、64声部、表情和长时间连续输出；测量实际DAC输出与端到端延迟。

本次仅形成兼容性审查记录，没有修改RTL、生成猜测引脚约束或烧录板卡。

## 来源

- Sipeed官方型号、底板说明及GPIO要求：<https://wiki.sipeed.com/hardware/en/tang/tang-mega-60k/mega-60k>
- 官方原理图入口：<https://dl.sipeed.com/shareURL/TANG/Mega_138K_60K/02_Schematic>
- 本地原理图：`C:/Users/asus/Desktop/Git/tmp/fpga_bom_20260917/NEO_Dock_60K_31004.pdf`；本次已查看其音频页图像`audio_page.png`。
- PTC官方PT8211格式说明：<https://www.princeton.com.tw/Portals/0/activeforums_Attach/PT8211_s.pdf?ver=8Q0ZJ0B7q1d09uLMwmZ3Kw%3D%3D>
- TI官方PCM5102A：<https://www.ti.com/product/PCM5102A>
