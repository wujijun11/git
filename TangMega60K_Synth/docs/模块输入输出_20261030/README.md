# 当前工程各模块输入输出索引

日期：2026-10-30。版本：codex/sustain-20261030，基于Chord F571，延音测试位流UserCode 7D2F。

**独立测试版，新增延音尚未上板验收。** 端口清点不等于实际硬件功能全部通过。

覆盖90个主工程HDL文件中的97个模块、1465个端口，另列122处已知模块命名实例。包括旧入口和条件分支；不包含厂商原语内部端口、测试台层次或软件每个函数。

先读[接口阅读方法](接口阅读方法.md)，再按下表看模块。想追一根线，查看[实例连接索引](实例连接索引.md)。

| 层次 | 模块数 | 端口数 | 文档 |
|---|---|---|---|
| 01 总装、启动与复位 | 5 | 94 | [逐模块输入输出](01-总装启动.md) |
| 02 时钟基础 | 3 | 25 | [逐模块输入输出](02-时钟.md) |
| 03 触摸采集与硬件驱动 | 5 | 101 | [逐模块输入输出](03-触摸驱动.md) |
| 04 通信、菜单与控制参数 | 17 | 260 | [逐模块输入输出](04-通信菜单表情.md) |
| 05 曲谱、录制与学习 | 2 | 55 | [逐模块输入输出](05-曲谱录制学习.md) |
| 06 V2队列、声部分配与延音 | 5 | 110 | [逐模块输入输出](06-V2声部分配延音.md) |
| 07 音频合成、混音与音效 | 15 | 151 | [逐模块输入输出](07-音频引擎.md) |
| 08 数字音频输出 | 1 | 15 | [逐模块输入输出](08-I2S输出.md) |
| 09 OLED、HDMI与灯板显示 | 18 | 187 | [逐模块输入输出](09-显示与灯板.md) |
| 10 备用入口、旧版与独立自检 | 26 | 467 | [逐模块输入输出](10-备用旧版入口.md) |

## 快速查找模块

| 模块 | 所属层 | 输入/输出/双向数量 |
|---|---|---|
| [PLL_INIT](02-时钟.md#pll_init) | 02 时钟基础 | 8 / 6 / 0 |
| [adsr](07-音频引擎.md#adsr) | 07 音频合成、混音与音效 | 4 / 3 / 0 |
| [audio_boot_status](01-总装启动.md#audio_boot_status) | 01 总装、启动与复位 | 2 / 1 / 0 |
| [audio_clock_48k](02-时钟.md#audio_clock_48k) | 02 时钟基础 | 1 / 3 / 0 |
| [audio_fx](07-音频引擎.md#audio_fx) | 07 音频合成、混音与音效 | 7 / 4 / 0 |
| [audio_monitor_cdc](09-显示与灯板.md#audio_monitor_cdc) | 09 OLED、HDMI与灯板显示 | 7 / 4 / 0 |
| [audio_plla_stage](02-时钟.md#audio_plla_stage) | 02 时钟基础 | 3 / 4 / 0 |
| [audio_system_v2](10-备用旧版入口.md#audio_system_v2) | 10 备用入口、旧版与独立自检 | 12 / 9 / 0 |
| [audio_system_v2_delay](10-备用旧版入口.md#audio_system_v2_delay) | 10 备用入口、旧版与独立自检 | 12 / 9 / 0 |
| [audio_system_v2_fm](10-备用旧版入口.md#audio_system_v2_fm) | 10 备用入口、旧版与独立自检 | 12 / 9 / 0 |
| [audio_visualizer](09-显示与灯板.md#audio_visualizer) | 09 OLED、HDMI与灯板显示 | 7 / 6 / 0 |
| [bin16_to_bcd](09-显示与灯板.md#bin16_to_bcd) | 09 OLED、HDMI与灯板显示 | 4 / 2 / 0 |
| [board_audio_16_48k_i2s_top](10-备用旧版入口.md#board_audio_16_48k_i2s_top) | 10 备用入口、旧版与独立自检 | 2 / 5 / 0 |
| [board_audio_48k_gao_top](10-备用旧版入口.md#board_audio_48k_gao_top) | 10 备用入口、旧版与独立自检 | 2 / 2 / 0 |
| [board_audio_48k_i2s_top](10-备用旧版入口.md#board_audio_48k_i2s_top) | 10 备用入口、旧版与独立自检 | 2 / 5 / 0 |
| [board_audio_diagnostic_top](10-备用旧版入口.md#board_audio_diagnostic_top) | 10 备用入口、旧版与独立自检 | 2 / 2 / 0 |
| [board_audio_gao_top](10-备用旧版入口.md#board_audio_gao_top) | 10 备用入口、旧版与独立自检 | 2 / 2 / 0 |
| [board_bringup_top](01-总装启动.md#board_bringup_top) | 01 总装、启动与复位 | 3 / 4 / 0 |
| [board_contest_full_top](01-总装启动.md#board_contest_full_top) | 01 总装、启动与复位 | 4 / 12 / 4 |
| [board_instrument_b_48k_gao_top](10-备用旧版入口.md#board_instrument_b_48k_gao_top) | 10 备用入口、旧版与独立自检 | 2 / 2 / 0 |
| [board_instrument_b_48k_i2s_top](10-备用旧版入口.md#board_instrument_b_48k_i2s_top) | 10 备用入口、旧版与独立自检 | 2 / 5 / 0 |
| [board_key_event_adapter](10-备用旧版入口.md#board_key_event_adapter) | 10 备用入口、旧版与独立自检 | 5 / 17 / 0 |
| [board_local_actions](01-总装启动.md#board_local_actions) | 01 总装、启动与复位 | 6 / 2 / 0 |
| [board_sequence16_48k_i2s_top](10-备用旧版入口.md#board_sequence16_48k_i2s_top) | 10 备用入口、旧版与独立自检 | 2 / 5 / 0 |
| [captain_control_top](10-备用旧版入口.md#captain_control_top) | 10 备用入口、旧版与独立自检 | 10 / 14 / 0 |
| [captain_control_top_v2](06-V2声部分配延音.md#captain_control_top_v2) | 06 V2队列、声部分配与延音 | 16 / 19 / 0 |
| [captain_system_top](10-备用旧版入口.md#captain_system_top) | 10 备用入口、旧版与独立自检 | 13 / 23 / 0 |
| [captain_system_top_v2](10-备用旧版入口.md#captain_system_top_v2) | 10 备用入口、旧版与独立自检 | 19 / 28 / 0 |
| [dds_lane](07-音频引擎.md#dds_lane) | 07 音频合成、混音与音效 | 3 / 2 / 0 |
| [event_fifo](10-备用旧版入口.md#event_fifo) | 10 备用入口、旧版与独立自检 | 8 / 9 / 0 |
| [event_fifo_v2](06-V2声部分配延音.md#event_fifo_v2) | 06 V2队列、声部分配与延音 | 9 / 10 / 0 |
| [expression_controls_v2](06-V2声部分配延音.md#expression_controls_v2) | 06 V2队列、声部分配与延音 | 7 / 5 / 0 |
| [expression_merge](04-通信菜单表情.md#expression_merge) | 04 通信、菜单与控制参数 | 13 / 6 / 0 |
| [fm_piano_lane](07-音频引擎.md#fm_piano_lane) | 07 音频合成、混音与音效 | 8 / 2 / 0 |
| [gain_percent_meter](04-通信菜单表情.md#gain_percent_meter) | 04 通信、菜单与控制参数 | 3 / 1 / 0 |
| [gain_saturator](07-音频引擎.md#gain_saturator) | 07 音频合成、混音与音效 | 4 / 4 / 0 |
| [headroom_smoother](07-音频引擎.md#headroom_smoother) | 07 音频合成、混音与音效 | 7 / 4 / 0 |
| [i2c_register_master](03-触摸驱动.md#i2c_register_master) | 03 触摸采集与硬件驱动 | 8 / 7 / 2 |
| [i2s_tx](08-I2S输出.md#i2s_tx) | 08 数字音频输出 | 5 / 10 / 0 |
| [instrument_full_system](01-总装启动.md#instrument_full_system) | 01 总装、启动与复位 | 10 / 44 / 2 |
| [instrument_system_v2](10-备用旧版入口.md#instrument_system_v2) | 10 备用入口、旧版与独立自检 | 21 / 21 / 0 |
| [interaction_top](10-备用旧版入口.md#interaction_top) | 10 备用入口、旧版与独立自检 | 8 / 13 / 0 |
| [interaction_top_v2](10-备用旧版入口.md#interaction_top_v2) | 10 备用入口、旧版与独立自检 | 23 / 24 / 0 |
| [key_map_transpose](04-通信菜单表情.md#key_map_transpose) | 04 通信、菜单与控制参数 | 2 / 1 / 0 |
| [learning_stepper](05-曲谱录制学习.md#learning_stepper) | 05 曲谱、录制与学习 | 11 / 7 / 0 |
| [live64_event_source](10-备用旧版入口.md#live64_event_source) | 10 备用入口、旧版与独立自检 | 7 / 11 / 0 |
| [live64_system_top](10-备用旧版入口.md#live64_system_top) | 10 备用入口、旧版与独立自检 | 4 / 10 / 0 |
| [local_action_arbiter](04-通信菜单表情.md#local_action_arbiter) | 04 通信、菜单与控制参数 | 7 / 5 / 0 |
| [menu_action_router](04-通信菜单表情.md#menu_action_router) | 04 通信、菜单与控制参数 | 11 / 10 / 0 |
| [menu_hierarchy](04-通信菜单表情.md#menu_hierarchy) | 04 通信、菜单与控制参数 | 9 / 16 / 0 |
| [mpr121_input_frontend](03-触摸驱动.md#mpr121_input_frontend) | 03 触摸采集与硬件驱动 | 7 / 23 / 2 |
| [mpr121_key_eventizer](03-触摸驱动.md#mpr121_key_eventizer) | 03 触摸采集与硬件驱动 | 10 / 10 / 0 |
| [mpr121_sampler](03-触摸驱动.md#mpr121_sampler) | 03 触摸采集与硬件驱动 | 5 / 11 / 2 |
| [mpr121_slider](03-触摸驱动.md#mpr121_slider) | 03 触摸采集与硬件驱动 | 6 / 8 / 0 |
| [note_arbiter](04-通信菜单表情.md#note_arbiter) | 04 通信、菜单与控制参数 | 5 / 4 / 0 |
| [oled_hierarchy_renderer](09-显示与灯板.md#oled_hierarchy_renderer) | 09 OLED、HDMI与灯板显示 | 16 / 1 / 0 |
| [oled_i2c_stream](09-显示与灯板.md#oled_i2c_stream) | 09 OLED、HDMI与灯板显示 | 8 / 4 / 2 |
| [oled_idle_view](09-显示与灯板.md#oled_idle_view) | 09 OLED、HDMI与灯板显示 | 6 / 1 / 0 |
| [oled_menu_renderer](09-显示与灯板.md#oled_menu_renderer) | 09 OLED、HDMI与灯板显示 | 15 / 1 / 0 |
| [oled_status_display](09-显示与灯板.md#oled_status_display) | 09 OLED、HDMI与灯板显示 | 23 / 2 / 2 |
| [oled_wave_capture](09-显示与灯板.md#oled_wave_capture) | 09 OLED、HDMI与灯板显示 | 6 / 1 / 0 |
| [oled_wave_renderer](09-显示与灯板.md#oled_wave_renderer) | 09 OLED、HDMI与灯板显示 | 4 / 1 / 0 |
| [performance_command_stage](04-通信菜单表情.md#performance_command_stage) | 04 通信、菜单与控制参数 | 9 / 6 / 0 |
| [performance_controller](05-曲谱录制学习.md#performance_controller) | 05 曲谱、录制与学习 | 17 / 20 / 0 |
| [pitch_expression](07-音频引擎.md#pitch_expression) | 07 音频合成、混音与音效 | 6 / 3 / 0 |
| [polar_lane](07-音频引擎.md#polar_lane) | 07 音频合成、混音与音效 | 8 / 3 / 0 |
| [poly16_event_source](10-备用旧版入口.md#poly16_event_source) | 10 备用入口、旧版与独立自检 | 7 / 11 / 0 |
| [remote_command_router](04-通信菜单表情.md#remote_command_router) | 04 通信、菜单与控制参数 | 24 / 28 / 0 |
| [remote_note_watchdog](04-通信菜单表情.md#remote_note_watchdog) | 04 通信、菜单与控制参数 | 8 / 8 / 0 |
| [remote_uart_rx](04-通信菜单表情.md#remote_uart_rx) | 04 通信、菜单与控制参数 | 3 / 3 / 0 |
| [remote_uart_transport](04-通信菜单表情.md#remote_uart_transport) | 04 通信、菜单与控制参数 | 8 / 11 / 0 |
| [remote_uart_tx](04-通信菜单表情.md#remote_uart_tx) | 04 通信、菜单与控制参数 | 4 / 2 / 0 |
| [runtime_audio_fx](07-音频引擎.md#runtime_audio_fx) | 07 音频合成、混音与音效 | 7 / 4 / 0 |
| [scope_renderer](09-显示与灯板.md#scope_renderer) | 09 OLED、HDMI与灯板显示 | 9 / 3 / 0 |
| [sequence16_event_source](10-备用旧版入口.md#sequence16_event_source) | 10 备用入口、旧版与独立自检 | 7 / 11 / 0 |
| [slider_expression_control](04-通信菜单表情.md#slider_expression_control) | 04 通信、菜单与控制参数 | 9 / 5 / 0 |
| [slider_gesture_input](04-通信菜单表情.md#slider_gesture_input) | 04 通信、菜单与控制参数 | 8 / 6 / 0 |
| [slider_menu_controller](04-通信菜单表情.md#slider_menu_controller) | 04 通信、菜单与控制参数 | 7 / 11 / 0 |
| [slider_volume_control](04-通信菜单表情.md#slider_volume_control) | 04 通信、菜单与控制参数 | 5 / 2 / 0 |
| [stereo_mixer](07-音频引擎.md#stereo_mixer) | 07 音频合成、混音与音效 | 6 / 2 / 0 |
| [stereo_peak_limiter](07-音频引擎.md#stereo_peak_limiter) | 07 音频合成、混音与音效 | 6 / 6 / 0 |
| [sustain_command_gate](06-V2声部分配延音.md#sustain_command_gate) | 06 V2队列、声部分配与延音 | 10 / 9 / 0 |
| [test_tone_source](10-备用旧版入口.md#test_tone_source) | 10 备用入口、旧版与独立自检 | 3 / 3 / 0 |
| [tone_demo_top](10-备用旧版入口.md#tone_demo_top) | 10 备用入口、旧版与独立自检 | 2 / 4 / 0 |
| [ui_tone_overlay](07-音频引擎.md#ui_tone_overlay) | 07 音频合成、混音与音效 | 8 / 4 / 0 |
| [video_clocking](09-显示与灯板.md#video_clocking) | 09 OLED、HDMI与灯板显示 | 2 / 3 / 0 |
| [video_serializer10](09-显示与灯板.md#video_serializer10) | 09 OLED、HDMI与灯板显示 | 4 / 1 / 0 |
| [video_sync_align](09-显示与灯板.md#video_sync_align) | 09 OLED、HDMI与灯板显示 | 5 / 3 / 0 |
| [video_timing_640x480](09-显示与灯板.md#video_timing_640x480) | 09 OLED、HDMI与灯板显示 | 2 / 5 / 0 |
| [video_tmds_encoder](09-显示与灯板.md#video_tmds_encoder) | 09 OLED、HDMI与灯板显示 | 6 / 1 / 0 |
| [video_tmds_tx](09-显示与灯板.md#video_tmds_tx) | 09 OLED、HDMI与灯板显示 | 9 / 4 / 0 |
| [voice_allocator](10-备用旧版入口.md#voice_allocator) | 10 备用入口、旧版与独立自检 | 10 / 14 / 0 |
| [voice_allocator_v2](06-V2声部分配延音.md#voice_allocator_v2) | 06 V2队列、声部分配与延音 | 11 / 14 / 0 |
| [voice_engine](07-音频引擎.md#voice_engine) | 07 音频合成、混音与音效 | 13 / 7 / 0 |
| [voice_state_ram](07-音频引擎.md#voice_state_ram) | 07 音频合成、混音与音效 | 5 / 1 / 0 |
| [wavetable_rom](07-音频引擎.md#wavetable_rom) | 07 音频合成、混音与音效 | 5 / 5 / 0 |
| [ws2812_guide](09-显示与灯板.md#ws2812_guide) | 09 OLED、HDMI与灯板显示 | 4 / 3 / 0 |

## 当前配置特别说明

- voice_state_ram默认WIDTH=101，当前voice_engine.u_state覆盖为125，不能按默认101位连当前音源。
- inout SCL/SDA是开漏双向总线，不能把它当成普通永远推挽的output。
- 旧headroom_smoother仍在源码中，当前固定增益分支不启用它。
- 当前新延音默认关闭；有延音接口不代表上电就一直延音。
- 上位机通信帧V1和内部音符控制V2是两套不同编号，不表示彼此不兼容。
- 源码链接指向本独立分支；重新修改接口后应重新生成，不要继续引用旧表。

[机器可读接口清单](接口原始清点.json) · [静态检查结果](接口核对结果.json) · [本次技术说明](本次接口整理实现说明.md)
