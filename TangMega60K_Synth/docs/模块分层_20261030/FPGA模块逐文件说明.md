# FPGA逐文件与逐模块分层

[先看总览](README.md) · [全部软件与工具文件](全部源码文件分类.md)

当前full工程列出90个HDL文件，定义97个模块；从board_contest_full_top静态遍历可达71个模块、65个文件。

这里的“静态可达”包含条件分支，并不表示每条分支最终都会占用硬件。模块数量也不等于振荡器数量。厂商PLLA、输出串行器等原语另由综合工具处理。

## 当前配置特别需要分清的分支

| 文件/开关 | 当前含义 |
|---|---|
| STABLE_CHORD_MIX_ENABLE=1 | 使用固定单声部标度和实际峰值保护，不按声部数跨档减半。 |
| headroom_smoother.v | 旧平滑方案留在源码；固定增益分支优先，因此没有接入当前音频计算。 |
| FX_ENABLE=0 / audio_fx.v | 音源内部固定延迟旁路；当前效果使用外层runtime_audio_fx。 |
| MENU_HIERARCHY_ENABLE=1 | 使用menu_hierarchy和slider_expression_control；旧平面菜单与独立音量映射仅供兼容。 |
| SUSTAIN_ENABLE=1 | 有延音控制能力，运行时开关默认关闭。 |
| FM_ENABLE=1 | FM音色仍可切换，主钢琴音色继续采用原八成分polar_lane。 |
| OLED/HDMI/WS2812 | 都读取状态或样本，不承担主音源运算。显示不应反压实时音源。 |

## 当前顶层关系中的文件

### 01 总装、启动与复位（4个文件）

| 文件 | 文件中定义的模块 | 职责 |
|---|---|---|
| [rtl/board/audio_boot_status.v](<https://github.com/wujijun11/git/blob/codex/sustain-20261030/TangMega60K_Synth/rtl/board/audio_boot_status.v>) | `audio_boot_status` | 在50MHz域观察PLL、复位、音频心跳和传感器状态，控制板载RGB诊断色；不接入音频ready/reset控制链，不保存黑匣子历史。 |
| [rtl/board/board_bringup_top.v](<https://github.com/wujijun11/git/blob/codex/sustain-20261030/TangMega60K_Synth/rtl/board/board_bringup_top.v>) | `board_bringup_top` | 底板基础按键消抖、上电等待及RGB状态编码；被完整板级顶层复用，也可独立排查板卡。 |
| [rtl/board/board_contest_full_top.v](<https://github.com/wujijun11/git/blob/codex/sustain-20261030/TangMega60K_Synth/rtl/board/board_contest_full_top.v>) | `board_contest_full_top`、`board_local_actions` | 当前物理板级顶层：连接50MHz输入、音频PLL、复位、实体引脚、HDMI、OLED和完整内部系统。 |
| [rtl/instrument_full_system.v](<https://github.com/wujijun11/git/blob/codex/sustain-20261030/TangMega60K_Synth/rtl/instrument_full_system.v>) | `instrument_full_system` | 完整系统的内部接线中心，连接传感器、菜单、远程命令、录放、64声部、音效和显示观察端口；不负责板卡物理引脚。 |

### 02 时钟基础（2个文件）

| 文件 | 文件中定义的模块 | 职责 |
|---|---|---|
| [rtl/clock/audio_clock_48k.v](<https://github.com/wujijun11/git/blob/codex/sustain-20261030/TangMega60K_Synth/rtl/clock/audio_clock_48k.v>) | `audio_clock_48k`、`audio_plla_stage` | 50MHz参考经两级PLLA得到49.152MHz；包含锁定资格判定和audio_plla_stage模块。参考时钟与音频工作时钟须分清。 |
| [rtl/clock/pll_init.v](<https://github.com/wujijun11/git/blob/codex/sustain-20261030/TangMega60K_Synth/rtl/clock/pll_init.v>) | `PLL_INIT` | 高云生成的PLL初始化IP，属于厂商代码；真实PLL配置需保留，不能当作自研音源创新。 |

### 03 触摸采集与硬件驱动（5个文件）

| 文件 | 文件中定义的模块 | 职责 |
|---|---|---|
| [rtl/sensors/i2c_register_master.v](<https://github.com/wujijun11/git/blob/codex/sustain-20261030/TangMega60K_Synth/rtl/sensors/i2c_register_master.v>) | `i2c_register_master` | 开漏I²C寄存器读写底层，含超时/总线恢复；供MPR121采集使用，不与OLED共用同一总线状态机。 |
| [rtl/sensors/mpr121_input_frontend.v](<https://github.com/wujijun11/git/blob/codex/sustain-20261030/TangMega60K_Synth/rtl/sensors/mpr121_input_frontend.v>) | `mpr121_input_frontend` | 组织三片MPR121采样、25键和四电极滑条，向上层报告有效触摸与故障。 |
| [rtl/sensors/mpr121_key_eventizer.v](<https://github.com/wujijun11/git/blob/codex/sustain-20261030/TangMega60K_Synth/rtl/sensors/mpr121_key_eventizer.v>) | `mpr121_key_eventizer` | 把完整触摸快照的按下/松开变化转成有来源的演奏事件；缓存批量变化，避免和弦漏键。 |
| [rtl/sensors/mpr121_sampler.v](<https://github.com/wujijun11/git/blob/codex/sustain-20261030/TangMega60K_Synth/rtl/sensors/mpr121_sampler.v>) | `mpr121_sampler` | MPR121初始化、配置读回、校准等待与一致性寄存器快照，检测传感器失联并重试。 |
| [rtl/sensors/mpr121_slider.v](<https://github.com/wujijun11/git/blob/codex/sustain-20261030/TangMega60K_Synth/rtl/sensors/mpr121_slider.v>) | `mpr121_slider` | 由四电极触摸强度计算加权位置0..3072；保留旧弯音输出能力，完整菜单模式不再直接用其弯音。 |

### 04 通信、菜单与控制参数（15个文件）

| 文件 | 文件中定义的模块 | 职责 |
|---|---|---|
| [rtl/control/expression_merge.v](<https://github.com/wujijun11/git/blob/codex/sustain-20261030/TangMega60K_Synth/rtl/control/expression_merge.v>) | `expression_merge` | 把本地与远程表情按有效掩码公平合并；滑条只更新gain，不覆盖弯音/颤音。 |
| [rtl/control/gain_percent_meter.v](<https://github.com/wujijun11/git/blob/codex/sustain-20261030/TangMega60K_Synth/rtl/control/gain_percent_meter.v>) | `gain_percent_meter` | 只观察已提交增益并转换OLED百分比，不阻塞或反馈控制音频样本链。 |
| [rtl/control/key_map_transpose.v](<https://github.com/wujijun11/git/blob/codex/sustain-20261030/TangMega60K_Synth/rtl/control/key_map_transpose.v>) | `key_map_transpose` | 对25键基础MIDI映射做有符号半音偏移，并限幅到0..127；本模块是组合映射，按住音符的松键对应由事件/曲谱控制层维护。 |
| [rtl/control/local_action_arbiter.v](<https://github.com/wujijun11/git/blob/codex/sustain-20261030/TangMega60K_Synth/rtl/control/local_action_arbiter.v>) | `local_action_arbiter` | 仲裁板载按钮和滑条菜单动作，反压时锁定请求，避免两个本地动作互相覆盖。 |
| [rtl/control/menu_action_router.v](<https://github.com/wujijun11/git/blob/codex/sustain-20261030/TangMega60K_Synth/rtl/control/menu_action_router.v>) | `menu_action_router` | 把菜单四区译为音色、音区、录放、曲谱动作及提示音；通过既有握手处理忙状态和重试。 |
| [rtl/control/menu_hierarchy.v](<https://github.com/wujijun11/git/blob/codex/sustain-20261030/TangMega60K_Synth/rtl/control/menu_hierarchy.v>) | `menu_hierarchy` | 当前分层菜单：声音、表情、录放、曲谱；声音页含延音入口。普通设置后显示波形，闲置10秒显示波形，之后触摸回音量。 |
| [rtl/control/note_arbiter.v](<https://github.com/wujijun11/git/blob/codex/sustain-20261030/TangMega60K_Synth/rtl/control/note_arbiter.v>) | `note_arbiter` | 公平选择实体、远程、曲谱等事件来源；接收方忙时保持已选择事件，防止漏音和重复。 |
| [rtl/control/performance_command_stage.v](<https://github.com/wujijun11/git/blob/codex/sustain-20261030/TangMega60K_Synth/rtl/control/performance_command_stage.v>) | `performance_command_stage` | 锁存录放/曲谱命令的操作码与80位参数，切断较长组合路径；后端执行前不提前宣告完成。 |
| [rtl/control/remote_command_router.v](<https://github.com/wujijun11/git/blob/codex/sustain-20261030/TangMega60K_Synth/rtl/control/remote_command_router.v>) | `remote_command_router` | 将校验后的命令分发为音符、表情、配置、曲谱操作和状态查询；含ACK及重试去重。新延音使用CONFIG目标2和READBACK选择器5/状态0x86。 |
| [rtl/control/remote_note_watchdog.v](<https://github.com/wujijun11/git/blob/codex/sustain-20261030/TangMega60K_Synth/rtl/control/remote_note_watchdog.v>) | `remote_note_watchdog` | 远程心跳失联或队列故障时释放远程来源的挂音；不误关实体键和脱机曲谱。 |
| [rtl/control/slider_expression_control.v](<https://github.com/wujijun11/git/blob/codex/sustain-20261030/TangMega60K_Synth/rtl/control/slider_expression_control.v>) | `slider_expression_control` | 把连续位置映射为音量0..2048、弯音±200音分或颤音0..100音分；只更新选中字段，已呈现命令不被覆盖。 |
| [rtl/control/slider_gesture_input.v](<https://github.com/wujijun11/git/blob/codex/sustain-20261030/TangMega60K_Synth/rtl/control/slider_gesture_input.v>) | `slider_gesture_input` | 把滑条位置拆成短触、左端长按、右端长按和连续控制位置；含消抖、区域迟滞及事件反压保持。 |
| [rtl/control/slider_menu_controller.v](<https://github.com/wujijun11/git/blob/codex/sustain-20261030/TangMega60K_Synth/rtl/control/slider_menu_controller.v>) | `slider_menu_controller` | 旧版平面四页菜单控制器；当前分层菜单开启时不会选择此generate分支，保留兼容与测试。 |
| [rtl/control/slider_volume_control.v](<https://github.com/wujijun11/git/blob/codex/sustain-20261030/TangMega60K_Synth/rtl/control/slider_volume_control.v>) | `slider_volume_control` | 单独的滑条音量映射；当前分层菜单采用slider_expression_control，此模块用于关闭分层菜单后的兼容分支。 |
| [rtl/remote/remote_uart_transport.sv](<https://github.com/wujijun11/git/blob/codex/sustain-20261030/TangMega60K_Synth/rtl/remote/remote_uart_transport.sv>) | `remote_uart_rx`、`remote_uart_transport`、`remote_uart_tx` | 包含remote_uart_rx、remote_uart_tx及传输包装：UART收发、16字节通信帧、CRC和队列。通信帧V1编号与内部控制V2编号相互独立。 |

### 05 曲谱、录制与学习（2个文件）

| 文件 | 文件中定义的模块 | 职责 |
|---|---|---|
| [rtl/performance/learning_stepper.v](<https://github.com/wujijun11/git/blob/codex/sustain-20261030/TangMega60K_Synth/rtl/performance/learning_stepper.v>) | `learning_stepper` | 学习模式判定器：等待松键、等待正确目标/和弦，按齐才前进；不限等待时间，本版不考核节奏。 |
| [rtl/performance/performance_controller.v](<https://github.com/wujijun11/git/blob/codex/sustain-20261030/TangMega60K_Synth/rtl/performance/performance_controller.v>) | `performance_controller` | 曲谱/录制RAM、时间调度、播放、停止释放、指引与学习的业务核心；当前板上曲谱容量1024条事件，不是1024首歌，也不保存PCM。 |

### 06 V2队列、声部分配与延音（5个文件）

| 文件 | 文件中定义的模块 | 职责 |
|---|---|---|
| [rtl/captain_control_top_v2.v](<https://github.com/wujijun11/git/blob/codex/sustain-20261030/TangMega60K_Synth/rtl/captain_control_top_v2.v>) | `captain_control_top_v2` | 当前V2控制层：把事件交给声部分配器，把表情参数按音频帧边界提交给音源。 |
| [rtl/control/sustain_command_gate.v](<https://github.com/wujijun11/git/blob/codex/sustain-20261030/TangMega60K_Synth/rtl/control/sustain_command_gate.v>) | `sustain_command_gate` | 开关式延音：位于原分配器与音源之间，记录已松键但暂不释放的声部；关闭延音逐个发送OFF，反压期间保持命令。 |
| [rtl/event_fifo_v2.v](<https://github.com/wujijun11/git/blob/codex/sustain-20261030/TangMega60K_Synth/rtl/event_fifo_v2.v>) | `event_fifo_v2` | 当前23位事件队列，保存来源、音高、力度和开关事件；处理同拍读写、环绕与反压，写缓存缩短控制路径。 |
| [rtl/expression_controls_v2.v](<https://github.com/wujijun11/git/blob/codex/sustain-20261030/TangMega60K_Synth/rtl/expression_controls_v2.v>) | `expression_controls_v2` | 保存待提交增益、弯音、颤音，在engine_sample_begin边沿统一提交；音源下一拍或之后读取新值。 |
| [rtl/voice_allocator_v2.v](<https://github.com/wujijun11/git/blob/codex/sustain-20261030/TangMega60K_Synth/rtl/voice_allocator_v2.v>) | `voice_allocator_v2` | 管理64个逻辑声部的占用、来源和音符匹配；产生cmd，等待释放尾音done后回收，满载有明确拒绝指示。 |

### 07 音频合成、混音与音效（15个文件）

| 文件 | 文件中定义的模块 | 职责 |
|---|---|---|
| [rtl/audio/adsr.v](<https://github.com/wujijun11/git/blob/codex/sustain-20261030/TangMega60K_Synth/rtl/audio/adsr.v>) | `adsr` | 计算起音、衰减、保持、释放包络及重触发过渡，决定声音随时间如何变响、变弱、结束。 |
| [rtl/audio/audio_fx.v](<https://github.com/wujijun11/git/blob/codex/sustain-20261030/TangMega60K_Synth/rtl/audio/audio_fx.v>) | `audio_fx` | 早期固定延迟/旁路包装；完整工程设置FX_ENABLE=0走旁路，实际可切换效果由runtime_audio_fx承担，并非两套延迟同时开启。 |
| [rtl/audio/dds_lane.v](<https://github.com/wujijun11/git/blob/codex/sustain-20261030/TangMega60K_Synth/rtl/audio/dds_lane.v>) | `dds_lane` | 32位相位累加器及频率控制字运算，产生波表地址；相位回绕形成周期振荡。 |
| [rtl/audio/fm_piano_lane.v](<https://github.com/wujijun11/git/blob/codex/sustain-20261030/TangMega60K_Synth/rtl/audio/fm_piano_lane.v>) | `fm_piano_lane` | 可切换的双运算器FM音色计算通道，保留为另一种声音；不是当前八成分钢琴的替代实现。 |
| [rtl/audio/gain_saturator.v](<https://github.com/wujijun11/git/blob/codex/sustain-20261030/TangMega60K_Synth/rtl/audio/gain_saturator.v>) | `gain_saturator` | 施加Q1.11总增益，输出宽位中间结果和24位饱和值；当前固定增益分支将宽位结果交给峰值保护，避免提前截断。 |
| [rtl/audio/headroom_smoother.v](<https://github.com/wujijun11/git/blob/codex/sustain-20261030/TangMega60K_Synth/rtl/audio/headroom_smoother.v>) | `headroom_smoother` | 旧方案：平滑按活跃声部数选择的混音增益；当前STABLE_CHORD_GAIN=1先选择固定增益分支，因此此平滑分支未启用。 |
| [rtl/audio/pitch_expression.v](<https://github.com/wujijun11/git/blob/codex/sustain-20261030/TangMega60K_Synth/rtl/audio/pitch_expression.v>) | `pitch_expression` | 对增益、弯音、颤音深度作逐帧平滑；查音高比例表，全局低频振荡器每采样帧只推进一次。 |
| [rtl/audio/polar_lane.v](<https://github.com/wujijun11/git/blob/codex/sustain-20261030/TangMega60K_Synth/rtl/audio/polar_lane.v>) | `polar_lane` | 八成分钢琴的计算通道之一：每通道分时处理4个分量，两通道合计8个；读取幅度/相位参数并保存分量状态，减少原I/Q运算占用。 |
| [rtl/audio/runtime_audio_fx.v](<https://github.com/wujijun11/git/blob/codex/sustain-20261030/TangMega60K_Synth/rtl/audio/runtime_audio_fx.v>) | `runtime_audio_fx` | 完整工程运行时干声、延迟、混响、合唱；共享历史RAM，处理切换清空与输出反压。 |
| [rtl/audio/stereo_mixer.v](<https://github.com/wujijun11/git/blob/codex/sustain-20261030/TangMega60K_Synth/rtl/audio/stereo_mixer.v>) | `stereo_mixer` | 将各声部的当前样本按声像累加为左右声道；使用扩展位宽，64声部最终仍是两路PCM。 |
| [rtl/audio/stereo_peak_limiter.v](<https://github.com/wujijun11/git/blob/codex/sustain-20261030/TangMega60K_Synth/rtl/audio/stereo_peak_limiter.v>) | `stereo_peak_limiter` | 当前和弦峰值保护：根据实际PCM峰值联动限制左右声道，快速压低、逐帧恢复；不因第二个音出现就固定减半。 |
| [rtl/audio/ui_tone_overlay.v](<https://github.com/wujijun11/git/blob/codex/sustain-20261030/TangMega60K_Synth/rtl/audio/ui_tone_overlay.v>) | `ui_tone_overlay` | 利用独立数学振荡器生成短提示音，并与音乐样本混合；没有存储“模式选择”等语音录音。 |
| [rtl/audio/voice_engine.v](<https://github.com/wujijun11/git/blob/codex/sustain-20261030/TangMega60K_Synth/rtl/audio/voice_engine.v>) | `voice_engine` | 音源主调度器：逐帧扫描声部，执行DDS/钢琴/FM、ADSR、力度和混音，输出左右24位PCM；遵守cmd/done/sample握手。 |
| [rtl/audio/voice_state_ram.v](<https://github.com/wujijun11/git/blob/codex/sustain-20261030/TangMega60K_Synth/rtl/audio/voice_state_ram.v>) | `voice_state_ram` | 保存各声部独立相位、频率、包络、音色等状态；用同步RAM代替大量分散寄存器。 |
| [rtl/audio/wavetable_rom.v](<https://github.com/wujijun11/git/blob/codex/sustain-20261030/TangMega60K_Synth/rtl/audio/wavetable_rom.v>) | `wavetable_rom` | 读取数学波形、音高频率字、力度及原钢琴查表数据；其ROM不是整段演奏录音。 |

### 08 数字音频输出（1个文件）

| 文件 | 文件中定义的模块 | 职责 |
|---|---|---|
| [rtl/i2s_tx.v](<https://github.com/wujijun11/git/blob/codex/sustain-20261030/TangMega60K_Synth/rtl/i2s_tx.v>) | `i2s_tx` | 把左右24位有符号PCM装入32位槽，以标准Philips I2S串行发送；带PCM缓冲和真实欠载计数。 |

### 09 OLED、HDMI与灯板显示（16个文件）

| 文件 | 文件中定义的模块 | 职责 |
|---|---|---|
| [rtl/performance/ws2812_guide.v](<https://github.com/wujijun11/git/blob/codex/sustain-20261030/TangMega60K_Synth/rtl/performance/ws2812_guide.v>) | `ws2812_guide` | 把25键目标/触摸状态转换成可寻址灯珠串行数据；需用灯号映射对应实体5×5空间顺序。 |
| [rtl/visual/audio_monitor_cdc.v](<https://github.com/wujijun11/git/blob/codex/sustain-20261030/TangMega60K_Synth/rtl/visual/audio_monitor_cdc.v>) | `audio_monitor_cdc` | 把音频样本安全传给显示时钟域；显示变慢可丢观察帧，但不能反压实时音源。 |
| [rtl/visual/audio_visualizer.v](<https://github.com/wujijun11/git/blob/codex/sustain-20261030/TangMega60K_Synth/rtl/visual/audio_visualizer.v>) | `audio_visualizer` | 计算波形、XY轨迹和64频点Goertzel显示数据；不是通用FFT，也不直接证明64复音谱峰。 |
| [rtl/visual/bin16_to_bcd.v](<https://github.com/wujijun11/git/blob/codex/sustain-20261030/TangMega60K_Synth/rtl/visual/bin16_to_bcd.v>) | `bin16_to_bcd` | 将16位无符号数逐拍转为四位十进制显示，超过9999饱和；避免大组合除法。 |
| [rtl/visual/oled_hierarchy_renderer.v](<https://github.com/wujijun11/git/blob/codex/sustain-20261030/TangMega60K_Synth/rtl/visual/oled_hierarchy_renderer.v>) | `oled_hierarchy_renderer` | 按当前分层页面、四区域、参数单位和延音实际状态生成OLED字节；由字模生成器和模板生成。 |
| [rtl/visual/oled_i2c_stream.v](<https://github.com/wujijun11/git/blob/codex/sustain-20261030/TangMega60K_Synth/rtl/visual/oled_i2c_stream.v>) | `oled_i2c_stream` | OLED专用开漏I2C写流，处理ACK、时钟延展、卡线恢复和超时；独立于三组触摸I2C，不阻塞音源。 |
| [rtl/visual/oled_idle_view.v](<https://github.com/wujijun11/git/blob/codex/sustain-20261030/TangMega60K_Synth/rtl/visual/oled_idle_view.v>) | `oled_idle_view` | OLED兼容显示覆盖层：根据空闲时间选择波形显示，不执行菜单动作；当前分层菜单主要通过外部waveform_view决定显示。 |
| [rtl/visual/oled_menu_renderer.v](<https://github.com/wujijun11/git/blob/codex/sustain-20261030/TangMega60K_Synth/rtl/visual/oled_menu_renderer.v>) | `oled_menu_renderer` | 按像素生成128×64菜单：中文模式、四区选项、高亮、录放计数与音量条；读取小字模ROM。 |
| [rtl/visual/oled_status_display.v](<https://github.com/wujijun11/git/blob/codex/sustain-20261030/TangMega60K_Synth/rtl/visual/oled_status_display.v>) | `oled_status_display` | 独立I²C OLED初始化/刷新，帧开始锁存显示状态，处理ACK/重试；屏幕掉线不阻塞音频。 |
| [rtl/visual/oled_wave_capture.v](<https://github.com/wujijun11/git/blob/codex/sustain-20261030/TangMega60K_Synth/rtl/visual/oled_wave_capture.v>) | `oled_wave_capture` | 捕获实际发送的左声道PCM，每4个样本形成一列，128列共约10.667ms；双缓冲保存每列上下界，显示不反压音频。 |
| [rtl/visual/oled_wave_renderer.v](<https://github.com/wujijun11/git/blob/codex/sustain-20261030/TangMega60K_Synth/rtl/visual/oled_wave_renderer.v>) | `oled_wave_renderer` | 将采样上下界画为OLED下方48像素的动感波形，保留上方模式标题；仅改变显示，不生成声音。 |
| [rtl/visual/scope_renderer.v](<https://github.com/wujijun11/git/blob/codex/sustain-20261030/TangMega60K_Synth/rtl/visual/scope_renderer.v>) | `scope_renderer` | 把音频观察数据和状态画成HDMI波形、频点柱与XY画面，不参与声音合成。 |
| [rtl/visual/video_clocking.v](<https://github.com/wujijun11/git/blob/codex/sustain-20261030/TangMega60K_Synth/rtl/visual/video_clocking.v>) | `video_clocking` | 生成HDMI 640×480所需像素/串行时钟；使用独立视频PLL。 |
| [rtl/visual/video_timing_640x480.v](<https://github.com/wujijun11/git/blob/codex/sustain-20261030/TangMega60K_Synth/rtl/visual/video_timing_640x480.v>) | `video_sync_align`、`video_timing_640x480` | 产生640×480行列计数、同步和有效显示区。 |
| [rtl/visual/video_tmds_encoder.v](<https://github.com/wujijun11/git/blob/codex/sustain-20261030/TangMega60K_Synth/rtl/visual/video_tmds_encoder.v>) | `video_tmds_encoder` | 把RGB字节/同步信号转换为TMDS编码，维持直流平衡。 |
| [rtl/visual/video_tmds_tx.v](<https://github.com/wujijun11/git/blob/codex/sustain-20261030/TangMega60K_Synth/rtl/visual/video_tmds_tx.v>) | `video_serializer10`、`video_tmds_tx` | 串行发送TMDS符号，含video_serializer10；连接高云DDR输出原语和HDMI引脚。 |

## 工程列出、但当前完整顶层未实例化的文件（25个）

这些文件用于旧接口、学习示例和专项板级测试。它们不是额外同时运行的音源；不要删除后再猜工程能否编译，也不要拿独立测试入口替换完整顶层。

| 文件 | 模块 | 用途 |
|---|---|---|
| [rtl/audio/audio_system_v2.v](<https://github.com/wujijun11/git/blob/codex/sustain-20261030/TangMega60K_Synth/rtl/audio/audio_system_v2.v>) | `audio_system_v2`、`audio_system_v2_delay` | V2控制、音源与I2S的逻辑集成示例，含干声及固定延迟两个顶层；不含当前整机全部外围。 |
| [rtl/audio/audio_system_v2_fm.v](<https://github.com/wujijun11/git/blob/codex/sustain-20261030/TangMega60K_Synth/rtl/audio/audio_system_v2_fm.v>) | `audio_system_v2_fm` | 可选FM音色的独立V2音频集成示例。 |
| [rtl/board/board_audio_16_48k_i2s_top.v](<https://github.com/wujijun11/git/blob/codex/sustain-20261030/TangMega60K_Synth/rtl/board/board_audio_16_48k_i2s_top.v>) | `board_audio_16_48k_i2s_top` | 16音同时发声的独立板级I2S测试入口。 |
| [rtl/board/board_audio_48k_gao_top.v](<https://github.com/wujijun11/git/blob/codex/sustain-20261030/TangMega60K_Synth/rtl/board/board_audio_48k_gao_top.v>) | `board_audio_48k_gao_top` | 准确48kHz时钟下的自动音频数字自检，供GAO采集，不等于外部DAC与喇叭验收。 |
| [rtl/board/board_audio_48k_i2s_top.v](<https://github.com/wujijun11/git/blob/codex/sustain-20261030/TangMega60K_Synth/rtl/board/board_audio_48k_i2s_top.v>) | `board_audio_48k_i2s_top` | 准确48kHz、外置DAC的独立音频自检入口，用于先排查声音输出链。 |
| [rtl/board/board_audio_diagnostic_top.v](<https://github.com/wujijun11/git/blob/codex/sustain-20261030/TangMega60K_Synth/rtl/board/board_audio_diagnostic_top.v>) | `board_audio_diagnostic_top` | 早期音频数字自检顶层，未采用最终准确48kHz外接DAC路径；仅作诊断与历史回归。 |
| [rtl/board/board_audio_gao_top.v](<https://github.com/wujijun11/git/blob/codex/sustain-20261030/TangMega60K_Synth/rtl/board/board_audio_gao_top.v>) | `board_audio_gao_top` | 早期自动循环音源/GAO观测顶层，用片内分析仪检查内部样本和状态。 |
| [rtl/board/board_instrument_b_48k_gao_top.v](<https://github.com/wujijun11/git/blob/codex/sustain-20261030/TangMega60K_Synth/rtl/board/board_instrument_b_48k_gao_top.v>) | `board_instrument_b_48k_gao_top` | 队员B交互到音源的独立GAO观测入口。 |
| [rtl/board/board_instrument_b_48k_i2s_top.v](<https://github.com/wujijun11/git/blob/codex/sustain-20261030/TangMega60K_Synth/rtl/board/board_instrument_b_48k_i2s_top.v>) | `board_instrument_b_48k_i2s_top` | 队员B交互到外置DAC的独立板级入口，保留在boardkeys48工程。 |
| [rtl/board/board_key_event_adapter.v](<https://github.com/wujijun11/git/blob/codex/sustain-20261030/TangMega60K_Synth/rtl/board/board_key_event_adapter.v>) | `board_key_event_adapter` | 把板载按键动作转换为测试用演奏事件；不等同于25键MPR121电极采集。 |
| [rtl/board/board_sequence16_48k_i2s_top.v](<https://github.com/wujijun11/git/blob/codex/sustain-20261030/TangMega60K_Synth/rtl/board/board_sequence16_48k_i2s_top.v>) | `board_sequence16_48k_i2s_top` | 16个音逐个播放、音间留空的独立板级测试入口。 |
| [rtl/captain_control_top.v](<https://github.com/wujijun11/git/blob/codex/sustain-20261030/TangMega60K_Synth/rtl/captain_control_top.v>) | `captain_control_top` | 第一阶段旧协议控制层，仅为旧测试与学习保留。 |
| [rtl/captain_system_top.v](<https://github.com/wujijun11/git/blob/codex/sustain-20261030/TangMega60K_Synth/rtl/captain_system_top.v>) | `captain_system_top` | 第一阶段旧控制与输出接口顶层，不能代替当前V2整机。 |
| [rtl/captain_system_top_v2.v](<https://github.com/wujijun11/git/blob/codex/sustain-20261030/TangMega60K_Synth/rtl/captain_system_top_v2.v>) | `captain_system_top_v2` | V2控制与I2S接口示例接线层；音源通过cmd/done/sample接口接入，不是完整实体系统。 |
| [rtl/diagnostics/live64_event_source.v](<https://github.com/wujijun11/git/blob/codex/sustain-20261030/TangMega60K_Synth/rtl/diagnostics/live64_event_source.v>) | `live64_event_source` | 可综合的64音开关事件发生器，支持启动/停止/反压/复位；事件仍经过声部分配器，不直接制造64路PCM。 |
| [rtl/diagnostics/live64_system_top.v](<https://github.com/wujijun11/git/blob/codex/sustain-20261030/TangMega60K_Synth/rtl/diagnostics/live64_system_top.v>) | `live64_system_top` | 64音诊断源接既有音源/I2S的独立逻辑示例；未填写未知板卡引脚。 |
| [rtl/diagnostics/poly16_event_source.v](<https://github.com/wujijun11/git/blob/codex/sustain-20261030/TangMega60K_Synth/rtl/diagnostics/poly16_event_source.v>) | `poly16_event_source` | 16个不同音高同时发声的可综合测试事件源。 |
| [rtl/diagnostics/sequence16_event_source.v](<https://github.com/wujijun11/git/blob/codex/sustain-20261030/TangMega60K_Synth/rtl/diagnostics/sequence16_event_source.v>) | `sequence16_event_source` | 16个音顺序演奏的可综合测试事件源，包含保持、间隔与完整松键。 |
| [rtl/event_fifo.v](<https://github.com/wujijun11/git/blob/codex/sustain-20261030/TangMega60K_Synth/rtl/event_fifo.v>) | `event_fifo` | 旧版无source字段的事件队列；只供旧接口路径使用。 |
| [rtl/instrument_system_v2.v](<https://github.com/wujijun11/git/blob/codex/sustain-20261030/TangMega60K_Synth/rtl/instrument_system_v2.v>) | `instrument_system_v2` | 较早的V2演奏系统接线入口；保留独立交互与音源验证，不是当前完整板级入口。 |
| [rtl/interaction_top.v](<https://github.com/wujijun11/git/blob/codex/sustain-20261030/TangMega60K_Synth/rtl/interaction_top.v>) | `interaction_top` | 旧版交互处理入口；用于早期队员B接口测试。 |
| [rtl/interaction_top_v2.v](<https://github.com/wujijun11/git/blob/codex/sustain-20261030/TangMega60K_Synth/rtl/interaction_top_v2.v>) | `interaction_top_v2` | V2交互处理入口：规范化选音和触发信息，经事件FIFO输出；保留独立联调。 |
| [rtl/test_tone_source.v](<https://github.com/wujijun11/git/blob/codex/sustain-20261030/TangMega60K_Synth/rtl/test_tone_source.v>) | `test_tone_source` | 数学方式实时生成测试音；用于检查输出协议，不是录音播放器。 |
| [rtl/tone_demo_top.v](<https://github.com/wujijun11/git/blob/codex/sustain-20261030/TangMega60K_Synth/rtl/tone_demo_top.v>) | `tone_demo_top` | 测试音与I2S的独立示例顶层，不含25键、曲库或完整演奏业务。 |
| [rtl/voice_allocator.v](<https://github.com/wujijun11/git/blob/codex/sustain-20261030/TangMega60K_Synth/rtl/voice_allocator.v>) | `voice_allocator` | 旧协议声部分配器，供第一阶段回归保留。 |

## 一个文件定义多个模块时怎么看

| 文件 | 包含的模块 |
|---|---|
| [rtl/audio/audio_system_v2.v](<https://github.com/wujijun11/git/blob/codex/sustain-20261030/TangMega60K_Synth/rtl/audio/audio_system_v2.v>) | audio_system_v2、audio_system_v2_delay |
| [rtl/board/board_contest_full_top.v](<https://github.com/wujijun11/git/blob/codex/sustain-20261030/TangMega60K_Synth/rtl/board/board_contest_full_top.v>) | board_contest_full_top、board_local_actions |
| [rtl/clock/audio_clock_48k.v](<https://github.com/wujijun11/git/blob/codex/sustain-20261030/TangMega60K_Synth/rtl/clock/audio_clock_48k.v>) | audio_clock_48k、audio_plla_stage |
| [rtl/remote/remote_uart_transport.sv](<https://github.com/wujijun11/git/blob/codex/sustain-20261030/TangMega60K_Synth/rtl/remote/remote_uart_transport.sv>) | remote_uart_rx、remote_uart_transport、remote_uart_tx |
| [rtl/visual/video_timing_640x480.v](<https://github.com/wujijun11/git/blob/codex/sustain-20261030/TangMega60K_Synth/rtl/visual/video_timing_640x480.v>) | video_sync_align、video_timing_640x480 |
| [rtl/visual/video_tmds_tx.v](<https://github.com/wujijun11/git/blob/codex/sustain-20261030/TangMega60K_Synth/rtl/visual/video_tmds_tx.v>) | video_serializer10、video_tmds_tx |

完整直接实例关系保存在本目录的模块清单.json中。阅读时先从父模块找到实例名，再看对应module定义；模块名与实例名不是同一个概念。
