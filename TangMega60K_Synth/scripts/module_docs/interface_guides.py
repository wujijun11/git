"""接口文档的时序、参数单位及初学者阅读说明。"""
import re

NOTES = {
    "audio_boot_status": "50MHz域只读观察48位启动快照、音频心跳并决定RGB颜色；不向功能链输出ready/reset，也不保存历史。输入多位快照是诊断观察，不能当严格原子跨时钟数据。",
    "board_contest_full_top": "物理板级顶层。sys_clk为50MHz；内部音频49.152MHz、视频25/125MHz。端口能否外接以CST和板卡丝印为准。多数子模块端口仅为FPGA内部连线。",
    "instrument_full_system": "完整逻辑系统。音频/通信/触摸/菜单使用clk，视频观察使用video_clk。公共event/cmd/done/sample协议未增加source字段。",
    "board_bringup_top": "50MHz域上电等待、板载按键消抖和RGB发送。key_n为低有效原始按键，keys_pressed为高有效按住状态。",
    "board_local_actions": "KEY0控制内置曲谱发声，KEY1控制离线指引；模式切换可能先停止并等待旧音释放。动作必须保持到local_action_ready。KEY2复位在板级父模块处理。",
    "audio_clock_48k": "50MHz参考经过两级PLL得到49.152MHz，locked经过资格等待；不是用计数器直接精确除出此频率。debug_pll_status只作诊断。",
    "audio_plla_stage": "PLL单级包装，clkin与mdclk职责不同；locked不是仅将原始锁定线直连。不要把此模块当作普通数据流水线。",
    "PLL_INIT": "高云厂商PLL初始化代码。接口是配置读写和锁定/复位控制，不是音频数据；正常接法沿用父级，不按音符实时更改。",
    "voice_allocator_v2": "event输入、cmd输出、done输入均为ready/valid。以(source,note)匹配按住的音；声部不偷取，释放尾音须等done后回收。done在空闲阶段优先于新事件。",
    "captain_control_top_v2": "封装原V2分配器和表情提交器。来源在分配器内部转换为cmd_voice，cmd中无需source。sample_begin由音源返回控制层。",
    "expression_controls_v2": "expr握手更新影子参数。engine_sample_begin上升沿提交；音源须在下一上升沿或之后读取新active_*。一帧64声部用同一份参数。",
    "event_fifo_v2": "push和pop分别握手，payload为on/source/note/velocity/timbre。背压时队头保持；同步RAM读与空转非空旁路由模块内部处理。",
    "sustain_command_gate": "普通ON/OFF只有下游音源接收后才确认上游；延音开启时的OFF记入位图后确认。关闭延音逐槽送OFF。out_valid=1而out_ready=0时命令冻结，不因开关变化撤回。",
    "voice_engine": "cmd输入、done输出和sample输出分别握手，互不混淆。sample_valid=1且sample_ready=0时左右PCM与valid保持。engine_sample_begin每个生成帧只提交一次；每帧内扫描64个逻辑声部。",
    "voice_state_ram": "单时钟同步读、条件写；读地址在上升沿采样，随后read_data更新。没有整块RAM复位，音源启动扫描初始化。默认WIDTH=101，当前voice_engine实例明确覆盖为125。",
    "adsr": "纯组合下一状态计算，没有clk、start或ready。输入某声部当前stage/level，输出next_stage/next_level，调用方负责每采样帧写回一次。finished同样是组合判断。",
    "dds_lane": "纯组合相位/地址运算，没有内部相位寄存器。phase由声部状态RAM保存，调度器每帧提交一次next_phase；不是每个49.152MHz周期都让音高前进。",
    "pitch_expression": "每个生成帧启动一次，必须在表情提交边沿之后启动。valid标示流水线结果，没有ready输入；上层按预定时序读取。全局LFO每帧只前进一次，背压不重复推进。",
    "polar_lane": "每条lane为每声部分时算4个独立分量，完整钢琴实例化两条lane。start后第1拍提供active/age/base_ftw，第3拍提供fundamental_ftw并保持到发射结束；valid给出合并结果，没有ready。",
    "fm_piano_lane": "按声部start启动一次FM计算，结果随valid输出，没有结果ready；调用者保证输入上下文和调度间隔。它是可选音色，不取代当前八成分钢琴。",
    "wavetable_rom": "clk上升沿同步读，输出在该边沿之后更新；没有ready/valid或复位。note_ftw、velocity_gain、wave_sample等来自各自ROM地址。",
    "stereo_mixer": "clear清空累加器，add时累加该声部样本。没有ready/valid，由音源状态机保证每帧清一次、每声部加一次。left_sum/right_sum是32位中间和，不是直接I2S线。",
    "gain_saturator": "乘法结果在clk上升沿寄存，后面缩放/饱和为组合运算；无reset或valid。调度器等待有效数据，不把启动时未定义乘积送出。当前峰值保护使用45位wide_*。",
    "stereo_peak_limiter": "输入/输出各自ready/valid。先锁存45位混音，再计算峰值所需增益；输出受反压时保持。只在真实峰值超限时压低，不按声部个数直接减半。",
    "headroom_smoother": "每个start推进一次旧分档增益平滑。它仍在静态源码分支中，但当前STABLE_CHORD_GAIN=1优先选固定增益，未启用此旧算法。",
    "runtime_audio_fx": "左右声道成对ready/valid传递，mode选择旁路/延迟/混响/合唱。音效RAM为历史样本缓存，不能解释为预录歌曲。",
    "audio_fx": "旧内部延迟/旁路包装，输入输出均握手。完整主工程FX_ENABLE=0走旁路，运行时效果由外层runtime_audio_fx承担。",
    "ui_tone_overlay": "PCM成对握手；prompt_valid是提示事件，不是主PCM的ready/valid流。提示由正弦数学运算产生，没有语音录音。",
    "i2s_tx": "sample握手接收一对24位PCM，内部两帧FIFO。BCLK_HALF_DIV=8且clk=49.152MHz时，BCLK=3.072MHz、LRCLK=48kHz。Philips I2S在LRCLK翻转后延迟一位发MSB；不能把I2S输出接到另一个内部时钟端口。",
    "remote_uart_rx": "以clk采样rx并接收UART字节。valid为接收完成脉冲，无ready，接收者必须当拍消费或缓存；framing_error表示停止位等格式错误。",
    "remote_uart_tx": "仅在busy=0时接受start及data。busy期间不能假设新的start会排队，后级传输包装负责调度。",
    "remote_uart_transport": "UART字节层内部用脉冲；完整16字节帧通过cmd/rsp的ready/valid交给路由层。此处不做业务重试去重，由remote_command_router处理。",
    "remote_command_router": "输入cmd是校验后的通信帧，不是音源cmd_voice命令。输出音符、表情、曲谱请求等。ACK和状态回传受rsp_ready反压；相同事务重试不能重复执行。",
    "remote_note_watchdog": "accepted观察已经接受的远程事件，无accepted_ready。静默超时/expire后逐音输出OFF，事件口受反压；不释放实体琴键来源。",
    "note_arbiter": "四路事件公平仲裁。in_valid/in_ready是4位逐路信号，payload每路23位。下游反压期间保持获选通路与整条负载，不能只保持音高。",
    "expression_merge": "A/B两路增量表情合并。输入mask按位更新，输出提供完整参数快照。反压时已呈现负载必须稳定，不能把正在等待的事务直接改为新位置。",
    "menu_hierarchy": "导航请求使用request_valid/ready，实际完成看action_done/action_error。fx_write、sustain_write等是单拍提交。预览区高亮不等于选项执行；闲置10秒显示波形。",
    "slider_gesture_input": "输出event为手势事件，配对event_ready；连续位置另用position_valid，不给每个位置设置事件排队。故障取消手势，不伪造松手。",
    "slider_expression_control": "连续位置更新尚未呈现的目标，输出expr接口遵守反压保持；mode=0音量、1弯音、2颤音。弯音松手归零，音量/颤音按既有保持规则。",
    "slider_volume_control": "旧独立音量路径：位置可合并为最新目标，但已呈现给expr接口的负载在反压时不变。当前分层菜单使用slider_expression_control。",
    "slider_menu_controller": "旧平面菜单兼容分支，当前完整工程启用分层菜单，不选择本分支。保留的ready/valid接口仍须遵守保持规则。",
    "menu_action_router": "request握手接收菜单业务。曲谱动作经action握手执行，可能先停止旧任务、等待或重试；busy不等于音源阻塞。prompt_valid/timbre_valid是提交脉冲。",
    "local_action_arbiter": "本地板载按键与菜单动作仲裁。out阻塞时固定选择和动作；local_ready/menu_ready只确认被选通的一路。",
    "performance_command_stage": "一拍寄存曲谱命令边界。先保存负载，后端实际接收同拍才确认对应上游来源，不提前ACK。",
    "performance_controller": "command口提交曲谱业务；event口输出调度后的音符。record_valid只观察已经接受的演奏，不能反压。record_read_index经同步RAM返回record_read_valid/row_payload。板内容量由SCORE_CAPACITY/RECORD_CAPACITY决定。",
    "learning_stepper": "row握手读取音符行，按目标聚合学习步骤；touch_ready是采集初始化条件。只有用户按齐目标才前进，可无限等待，不能用普通定时播放代替。",
    "ws2812_guide": "按guide_mask/touch_mask快照编码整帧灯光，不向触摸/音源输出ready。busy和frame_done只描述灯板发送状态；实际灯序由PIXEL_KEY_MAP标定。",
    "mpr121_input_frontend": "三条独立I2C总线并行采集。key事件与expr_update分别握手；ready/fault为三块芯片状态位图。第一块ELE8..11作为滑条，快键通道与完整滑条快照分开。",
    "mpr121_sampler": "一块MPR121驱动。完整43字节快照用snapshot_valid/ready；EARLY_KEY_ENABLE时前2字节通过独立early_key口提前上报。IRQ须已在父级同步。",
    "mpr121_key_eventizer": "逐芯片snapshot_valid/ready接收触摸位图，再序列化为key事件。为整批转移预留空间；key_valid阻塞时不丢松键。同一次持键沿用按下时的音高/音色映射。",
    "mpr121_slider": "snapshot_strobe启动一次完整快照的位置计算。输入快照不是每周期变动的实时模拟电压；内部除法分时执行。expr_update输出可反压，active/position作为当前状态另行观察。",
    "i2c_register_master": "cmd握手启动一次寄存器事务，忙时不接新事务。读取字节通过rdata_valid脉冲输出，没有rdata_ready；done标志整次事务结束，error说明结果。SCL/SDA只拉低或高阻释放。",
    "oled_i2c_stream": "cmd握手启动OLED写事务，data_valid/ready提交1..128字节。done/error表示该事务完成/失败；模块独立恢复错误，不应拖住音源。",
    "oled_status_display": "一帧刷新开始时锁存菜单状态。audio_sample_valid只用于观察波形，无音频ready；OLED掉线重试不接入音源复位链。当前分层菜单使用external_waveform_view。",
    "oled_hierarchy_renderer": "输入OLED页/列与已锁存UI状态，输出8位像素字节；内部字模读取与绘制为流水线，父级按既定拍数对齐，不是I2C握手模块。",
    "oled_menu_renderer": "旧菜单字模渲染路径，接口为像素页/列与状态，无ready。当前分层界面由oled_hierarchy_renderer替代。",
    "oled_wave_capture": "sample_valid观察实际PCM，每4样本形成一列。两个128列区轮换，frame_snapshot锁定前台，read_bounds按同步读延迟返回；不反压音源。",
    "oled_wave_renderer": "输入已对齐的列上下界，输出对应OLED页字节；内部页/列延迟一拍用于匹配捕获RAM。",
    "oled_idle_view": "显示选择器，不执行菜单动作、不消费触摸事件。当前分层菜单可通过外部策略取代本兼容覆盖分支。",
    "bin16_to_bcd": "start启动一次逐拍转换，完成时done指示；没有ready队列，调用者需在转换结束后使用digits。输入超过9999时按实现饱和。",
    "audio_monitor_cdc": "双时钟观察桥，不给主音源回传反压；源域忙时可以丢观察样本并累计drop_count。不要直接用多位异步PCM绕过此桥。",
    "audio_visualizer": "输入样本为观察脉冲，没有sample_ready。64频点Goertzel忙时丢观察样本并统计；频点数不能当作通过64音频谱验收。",
    "scope_renderer": "像素域绘图。wave_read_index/xy_read_addr驱动观察存储读取，rgb为绘图结果，不参与音频运算。",
    "video_clocking": "50MHz参考生成25MHz像素和125MHz串行时钟；locked资格判定后才释放视频链。reset高有效。",
    "video_timing_640x480": "每像素时钟推进坐标与同步，de限定可见区；行/场同步不是音频控制。",
    "video_sync_align": "将hsync/vsync/de延迟LATENCY拍，与绘图器像素流水线保持一致。",
    "video_tmds_encoder": "每像素时钟编码8位颜色为10位符号，消隐区改发控制码并维护编码平衡。",
    "video_tmds_tx": "将像素域符号送入串行域，输出差分TMDS。clk_serial不是软件串口波特率时钟。",
    "video_serializer10": "25MHz加载10位符号、125MHz双边沿串行输出；厂商输出原语与仿真分支不同，不能只凭软件波形当HDMI实测。",
}

PARAMETERS = {
    "VOICE_COUNT": "逻辑声部槽数量；当前完整工程64。",
    "ID_WIDTH": "声部编号位数，须能编码VOICE_COUNT个槽；64槽用6位。",
    "SOURCE_WIDTH": "来源编号位数，V2完整工程6位。",
    "WIDTH": "RAM一行数据位数，父实例可覆盖，见实例参数表。",
    "SAMPLE_RATE": "实际音频采样率，单位Hz，当前完整工程48000。",
    "CLK_HZ": "本模块工作时钟频率，单位Hz；用于换算计数周期，不创建新时钟。",
    "BAUD": "UART波特率，单位bit/s，常用115200。",
    "UART_BAUD": "FPGA与C3 UART波特率，单位bit/s。",
    "BCLK_HALF_DIV": "I2S位时钟半周期分频数；Fs=clk/(该值×2×64)。",
    "PCM_SHIFT": "OLED显示幅度右移位数，仅影响波形显示，不改变声音音量。",
    "LANE": "钢琴分量计算通道编号，完整工程使用0和1两条lane。",
    "STABLE_CHORD_GAIN": "固定单声部混音标度与实际峰值保护使能，优先于旧分档方案。",
    "STABLE_CHORD_MIX_ENABLE": "完整工程固定增益和弦方案选择开关，当前为1。",
    "HEADROOM_SMOOTH": "旧按声部数分档增益平滑使能；固定增益分支优先时不生效。",
    "AUTO_HEADROOM": "旧按声部数选择混音放大倍率的开关。",
    "CEILING": "峰值保护振幅阈值，单位为24位PCM整数刻度。",
    "RELEASE_STEP_Q16": "峰值保护每接收一帧恢复的增益步长，65536=1倍。",
    "MASTER_SHIFT": "主混音增益缩放移位数，必须结合gain_saturator实现理解。",
    "SHIFT": "增益运算结果附加移位数，见对应模块注释。",
    "GAIN_STEP": "每生成帧的增益平滑步长，单位Q1.11整数刻度。",
    "BEND_STEP": "每生成帧弯音平滑步长，单位音分。",
    "DEPTH_STEP": "每生成帧颤音深度平滑步长，单位音分。",
    "SCORE_CAPACITY": "板内曲谱RAM容量，单位事件条数，不是歌曲数。",
    "RECORD_CAPACITY": "板内演奏录制RAM容量，单位事件条数。",
    "CHORD_SLOTS": "可保留独立和弦所有权的槽数量。",
    "MAX_CHORD_NOTES": "一个和弦输入能包含的最大音符数。",
    "LED_COUNT": "可寻址灯珠数量；当前5×5为25。",
    "PIXEL_KEY_MAP": "每颗灯对应的实体键编号打包表，用于实际灯序标定。",
    "GUIDE_PIXEL_KEY_MAP": "完整顶层传给灯板驱动的灯号到键号映射。",
    "PAN_SPREAD": "声像分散选择：0居中，非0按声部编号奇偶采用左右强弱比例。",
    "BOOT_DIAGNOSTIC": "板载RGB使用启动/PLL/心跳诊断色的编译参数，不是运行时菜单。",
    "LEFT_STEP": "左路测试三角波32位相位步长；默认按48kHz生成440Hz。",
    "RIGHT_STEP": "右路测试三角波32位相位步长；默认按48kHz生成440Hz。",
    "HIST_SIZE": "音效历史RAM深度，单位样本存储项。",
    "HIST_AW": "音效历史RAM地址位宽，单位bit。",
    "COLUMN_OFFSET": "OLED显存列偏移，单位列，取决于控制器映射。",
    "INPUT_MHZ": "PLL输入参考频率，单位MHz。",
    "CLK_PERIOD": "PLL初始化参考周期，单位ns，依现有厂商配置使用。",
    "MULTI_FAC": "厂商PLL初始化倍频参数，不能当作主音频采样率。",
    "MDIV": "PLL配置中的倍频/分频字段，须结合PLLA参数及官方定义。",
    "ODIV": "PLL输出分频字段，须结合PLLA配置。",
    "ODIV_FRAC": "PLL输出分频的小数字段，不能按普通整数Hz理解。",
    "LATENCY": "信号对齐延迟，单位本模块时钟拍数。",
    "ELECTRODES": "该MPR121启用的电极数量。",
    "CALIBRATION_SNAPSHOTS": "初始化校准所需连续完整快照数量。",
    "MAX_RETRIES": "允许重试的最大次数。",
    "BASE_NOTE": "自检首个MIDI音高编号。",
    "VELOCITY": "自检事件的MIDI力度编号0..127。",
    "SOURCE_ID": "自检事件使用的来源编号。",
    "SOURCE_BASE": "按键/自检来源编号基址，须避免与其他来源冲突。",
    "SCORE_SOURCE_BASE": "普通曲谱按键来源编号基址。",
    "RECORD_SOURCE_BASE": "录制回放来源编号基址。",
    "DIRECT_SCORE_SOURCE": "直接MIDI音高曲谱的来源编号。",
    "POSITION_MIN": "滑条位置标定下限，单位位置刻度。",
    "POSITION_MAX": "滑条位置标定上限，当前常用3072。",
    "MIN_WEIGHT": "判定滑条有效触摸所需最小总权重。",
    "HYSTERESIS": "滑条四区边界迟滞，单位位置刻度。",
    "GAIN_HYSTERESIS": "音量目标变化死区，单位Q1.11增益整数刻度。",
    "TOUCH_THRESHOLD": "MPR121触摸阈值寄存器数值，不是伏特。",
    "RELEASE_THRESHOLD": "MPR121释放阈值寄存器数值，不是伏特。",
    "FILTER_CDC": "MPR121采样/充电电流相关寄存器配置编码。",
    "FILTER_CDT": "MPR121采样/充电时间相关寄存器配置编码。",
    "STATUS_MODE": "板载RGB显示状态选择，依模块已有分支解释。",
}


def parameter_description(name):
    if name in PARAMETERS:
        return PARAMETERS[name]
    if name == "ROM_DIR" or name.endswith("_FILE"):
        return "离线ROM/字模/系数文件路径；不是运行时播放的音频文件。"
    if name.endswith("_CYCLES"):
        return "计数门限/步长，单位本模块时钟周期；换算时间必须使用实际连接时钟。"
    if name.endswith("_MS"):
        return "时间参数，单位毫秒。"
    if name.endswith("_US"):
        return "时间参数，单位微秒。"
    if name.endswith("_NS"):
        return "时间参数，单位纳秒。"
    if name.endswith("_HZ"):
        return "频率配置，单位Hz；用于计数/分频换算。"
    if name.endswith("_Q15"):
        return "Q15比例系数，32768对应1倍；反馈系数须满足稳定性约束。"
    if name in {"I2C_ADDR", "ADDRESS", "OLED_ADDRESS", "ADDR0", "ADDR1", "ADDR2"}:
        return "7位I2C从机地址，不含读写位。"
    if name.endswith("_AWIDTH") or name == "AWIDTH":
        return "地址位数，须覆盖相应缓存/槽数量。"
    if name.endswith("_DEPTH") or name == "DEPTH":
        return "缓存/队列容量，单位条或存储项，具体随模块。"
    if name.endswith("_ENABLE") or name.startswith("ENABLE") or name == "ENABLE":
        return "功能/接口选择参数，通常0关闭、1开启；不是运行时按钮。"
    if name.endswith("BRIGHTNESS"):
        return "灯珠亮度8位刻度0..255，增大前须核对供电余量。"
    if name in {"DELAY_LENGTH", "DELAY_SAMPLES", "COMB0", "COMB1", "COMB2", "COMB3", "AP0", "AP1", "CHORUS_BASE", "CHORUS_DEPTH"}:
        return "音效/延迟线长度或偏移，单位音频样本；时间=样本数/采样率。"
    if "NOISE" in name:
        return "滑条电极噪声门限，单位采样差分刻度。"
    if re.search(r"GAIN\d$", name):
        return "滑条电极校准增益，当前256对应1倍。"
    if "CENTS" in name or name == "SLIDER_BEND_MAX":
        return "弯音/迟滞/死区范围，单位音分，100音分=1半音。"
    if name.startswith("SLIDER_"):
        return "传给滑条采集器的标定配置，单位同对应位置/权重参数。"
    if name == "RX_TIMEOUT_BITS":
        return "通信接收超时长度，单位UART位时间。"
    if name == "TIMEOUT_SECONDS":
        return "远程看门狗静默超时，单位秒。"
    if name == "PERFORMANCE_MENU_EDGE":
        return "旧菜单连续控制/菜单区域划分边界，单位位置刻度。"
    raise ValueError(f"缺少参数说明：{name}")


def timing_description(module):
    name = module["name"]
    if name in NOTES:
        return NOTES[name]
    path = module["file"]
    if "/diagnostics/" in path:
        return "独立可综合自检入口。start/stop管理任务，event口仍经原分配器发声；遇反压须保持事件。此文件未接入当前完整顶层，不能当作当前位流默认功能。"
    if name.startswith("board_"):
        return "独立板级调试/自检入口，未由当前完整顶层实例化。其采样时钟、诊断输出和按键行为以本入口参数与实例连接为准，不能替代ContestFull完整工程。"
    if name.startswith("audio_system_"):
        return "音源与V2控制/I2S的独立包装示例，未接入当前完整顶层。event、expr、cmd/done/sample分别沿各子模块握手，不能把它当新增并行工作的一套音源。"
    if name.endswith("_v2"):
        return "保留的V2集成边界/示例，当前顶层是否使用须看可达状态。输入valid必须保持负载到配对ready，状态输出和观察脉冲不因此自动成为流接口。"
    if name in {"event_fifo", "voice_allocator", "captain_control_top", "captain_system_top", "interaction_top"}:
        return "旧版协议入口，未接入当前完整顶层。缺少V2来源所有权等扩展，接口用于历史回归，不可直接替换当前V2模块。"
    if name in {"test_tone_source", "tone_demo_top"}:
        return "早期数学测试音源/示例入口，不是预录PCM播放。未接入当前完整顶层；默认频率/时钟参数仅对此示例有效。"
    if name == "key_map_transpose":
        return "组合映射：25个MIDI音高加有符号半音偏移并饱和到0..127，没有逐笔握手。已按住音符的原映射由后续持键管理保存。"
    if name == "gain_percent_meter":
        return "把已提交增益转换为OLED显示百分比，不参与音量计算，不反压音源。"
    raise ValueError(f"缺少时序说明：{name}")
