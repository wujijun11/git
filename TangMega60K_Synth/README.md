# 弦光：Tang Mega 60K 电子乐器工程

**2026-10-30本分支最新：开关式延音独立测试版，尚未上板测试。** 默认关闭延音，可通过滑条菜单、Windows 1.5.2-sustain-test和Android 1.9-sustain-test控制；C3固件不变。保留原F571固定增益和弦、触摸提前上报、原V2接口与音源算法。[下载与验证范围](releases/sustain-20261030/README.md) · [延音技术说明](docs/开关式延音与蓝牙控制实现说明_20261030.md) · [模块分层](docs/模块分层_20261030/README.md) · [每个模块的输入输出](docs/模块输入输出_20261030/README.md)。本分支不合并main，新增延音实际听感、真实BLE、OLED新增页面、5×5灯板联合运行与长期稳定性仍待实测；原F571发布包不变。下方“最新/当前”均为对应日期的历史记录。

**2026-10-28本分支最新测试版：和弦稳定音量＋触摸提前上报。** [下载完整FS与GUI源码包](releases/chord-touch-20261028/README.md) · [技术实现说明](docs/和弦稳定混音与触摸提前上报实现说明_20261028.md) · [发布记录与验证范围](docs/降低延迟与稳定音量发布记录_20261028.md)。保持固定声部标度，实际过载时峰值压缩；前两字节触摸状态提前发键，43字节滑条数据仍完整读取。54项相关仿真与完整Gowin时序通过，数字通路对照节省约0.94～0.96ms。新FS的UserCode为`0x0000F571`，本版尚未上板，物理总延迟、听感和长期稳定性待实测。保留旧测试包回退，未宣称修复核心板熄灯。以下为对应日期的历史记录。

**2026-10-27本轮完整更新**：当前测试源为OLED空闲真实波形版，Windows为1.5.1原生后台曲谱版。下载[FPGA源码/位流](releases/oled-idle-wave-20261027/README.md)、[Windows便携包](releases/windows-minimized-20261027/README.md)，先看[版本、历史问题与解决方案](docs/版本问题与解决方案汇总_20261027.md)。用户反馈最新FPGA版可以发声；**OLED屏幕和5×5灯板尚未实测**。Windows真实最小化窗口＋模拟设备专项通过，真实蓝牙试听仍待复测。故障平滑位流继续暂停，持续音随复音数被压低的策略尚未修改。下方按各自日期保留历史交付状态，不将旧“当前/尚未上板/未上传”字样当作本轮结论。

2026-10-27 OLED空闲波形测试版：当前分支`codex/oled-idle-waveform`。滑条静置3秒，OLED在原页面标题下显示实际I2S左声道波形；触摸恢复原页面，总菜单/子页都不再空闲自动回音量。24项选定ModelSim实际通过，完整Gowin布局布线Setup/Hold余量0.381/0.163ns，BSRAM106/118；为时序将曲谱按键元数据改为同拍分组写使能并通过独立参考比较。原R2位流保留，本版尚未上板、未自动下载或上传。见[实现说明与预览](docs/OLED空闲实时波形实现说明_20261027.md)及[独立测试交付包](releases/oled-idle-wave-20261027/ContestFull_OLEDIdleWave_TEST1024.zip)。以下保留历史记录，“当前/最新”按对应日期和分支解释。

**2026-10-27上板异常：暂停使用`ContestFull_HeadroomSmooth_TEST1024.fs`。**用户确认相同接线下平滑新版实体键失效、C3可发现但FPGA握手超时，回退`ContestFull_SliderVolume_TEST1024.fs`后恢复。原42项仿真和STA通过仍有效，但不能作为这份位流实板可用的证明。当前为独立`codex/headroom-board-triage`排查分支，临时用已有RGB观察公共时钟/复位启动链，不包含历史黑匣子。见[上板排查说明](docs/混音平滑上板异常排查_20261027.md)。

2026-10-27实板反馈追加：用户确认`ContestFull_HeadroomBootProbe_R2.fs`为绿色、FPGA握手成功、实体琴键恢复正常发声。当前固定保留这份构建，作为通过上述单次实板检查的测试候选；原故障平滑位流继续暂停。根因、多次冷启动和长时间稳定性尚未确认，不为去除诊断灯而立即重新布局布线。

当前在**本地混音增益平滑测试分支 `codex/headroom-smoothing`**，以`20aa6f9`保存的滑条音量版源码为基线。故障黑匣子/模式同步试验按用户决定取消采用，仅保留在另一独立本地分支。本轮只验证自动余量跨档的短斜坡，原音色、稳态音量、64声部和公共V2接口保持；原理、测试与时序结果见[增益平滑实现说明](docs/混音增益跨档平滑实现说明_20261027.md)。不自动下载、不推送或合并main。此前源码清单仍冻结到`603a417`，从[作品源码阅读入口](docs/作品文档准备_20261026/README.md)查看。

2026-10-27增益平滑测试版：42项选定ModelSim回归满足预期（40正常、2预期拒绝），完整隔离构建Setup/Hold余量0.338/0.101ns、违反端点0。跨档增益最多64帧过渡，稳态标度保持；相对原版增加121寄存器与4个DSP报告单位，BSRAM不变，Setup余量仍比原版小。新位流`ContestFull_HeadroomSmooth_TEST1024.fs`、GUI源码、PCM试听和完整证据位于[本地测试交付包](releases/headroom-smoothing-20261027/ContestFull_HeadroomSmooth_TEST1024.zip)；尚未上板，不能宣称解决现场噼啪。旧版下述交付保留。

2026-10-26最新测试版：默认滑条连续音量、长按菜单与OLED四区显示；38个选定ModelSim用例满足预期，完整隔离构建Setup/Hold余量0.618/0.093ns。位流`ContestFull_SliderVolume_TEST1024.fs`及配套GUI源码位于[滑条音量交付ZIP](releases/slider-volume-20261026/ContestFull_SliderVolume_TEST1024.zip)；构建快照关闭GAO，工作区GPRJ保留调试配置。实物滑条、OLED、灯序和总延迟待验收，见[滑条音量实现说明](docs/滑条音量演奏模式实现说明_20261026.md)。以下条目按日期保留历史状态，不能将较早的“当前/最新”入口当作本版产物。

2026-10-26（本地OLED接入）：完整顶层新增独立四针128×64 I²C状态屏，显示中文菜单、分区反显和录放状态。20项ModelSim针对性回归与实际Gowin构建通过，Setup/Hold违反端点均为0，最小余量0.046/0.001ns，余量仍偏紧。音源算法与客户端未改，旧LearningMode交付保留；本地新位流位于 `delivery-oled-integration/fpga/ContestFull_OLED_Learning1024.fs`，尚未下载实测。接线、模块说明和复现命令见[OLED完整工程接入](docs/OLED完整工程接入_20261026.md)。此条不代表已推送GitHub。

2026-10-23：当前完整主工程、ESP32-C3 桥接固件与 Windows **Tang Neon Studio 1.0.4** 源码已更新。FPGA 主源对应已构建的 `8FE0`；另提供只增加被动串口观察的完整工程副本，其实板 SRAM 下载编号为 `3B9F`。C3 已烧录并校验，但 FPGA 的蓝牙协议 ACK 仍未验收通过，未完成 FPGA Flash 固化；不能把编译、下载或蓝牙配对当作整机连接成功。最新状态、接线与重建入口见[当前工程状态](docs/当前工程状态-20261023.md)。下方保留各日期的历史记录。

2026-10-17：用户确认材料已到齐，进入装配与实物联调。已沿60K核心BTB→31005底板BTB→外部接口核对12个新信号与3.3V取电位置，见[整机连线方案](docs/整机连线方案-20261017.md)。先焊接琴键8/8/9针和滑条4针，现场认准接口pin1并核对供电，再按单组8键→25键→滑条→LED→蓝牙逐项验收；到货和原理图核对不等于实测通过。当前文件、分步接线与记录见[到货装配与联调](docs/到货装配与联调-20261017.md)。

2026-10-16继续交付核验（10月15日修改）：修复手机曲谱加载、批量上传、文件选择/导出的异步竞态，以及文件错误误断正常BLE的问题；APK更新为**1.2/code 3**，新增网页11项和原生8项异步检查通过，实际构建、lint与签名/资产校验通过。C3增加CRC辅助的重叠帧头恢复，29项宿主测试和目标编译通过，静态RAM不变。本轮FPGA分组检查候选实际Setup只有0.003ns，未采用；当前继续保留**Setup 0.252ns/Hold 0.126ns、BSRAM106/118**的已验版本。完整性导出专项7项通过，新受验包含当前位流、APK、C3固件与证据；尚未烧录或射频/整机实测，见[本轮优化与交付包](verification/optimization-20261015/README.md)。下列记录保留各自验证时点。

2026-10-15蓝牙复查：修复C3报错后等待异步断连期间继续转发、旧会话故障覆盖新会话等问题；手机加入GATT连接/发现/通知订阅15秒分阶段超时、旧扫描/选择隔离，以及握手完成前的演奏/参数/心跳门禁。C3实际代码17项宿主回归通过并重新编译；新版APK1.1实际构建、lint错误/警告0、签名及包内资源一致性通过。当前FPGA/桥/手机交付237项完整性检查通过；增强音源等价在ModelSim/Icarus各50,106拍通过。新产物尚未烧录或手机射频实测，证据与APK路径见[本次复查交付](verification/code-ble-review-20261015/README.md)。

2026-10-15复核（10月14日完成Hold优化）：`polar_lane`状态RAM写入增加同一真实时钟的下降沿暂存，保持原上升沿写回拍次，不增加整周期延迟。实际完整Gowin构建的**Hold由0.035ns提高到0.126ns，Setup为0.252ns**（较0.272ns减少0.020ns）；Recovery/Removal为4.496/0.676ns，时序违规0。Logic21905、Register15726、BSRAM106/118（约90%）、DSP50.5/118；CST/SDC、时钟、ROM、声部数和接口不变。新源码已采用，核心33项重新实际通过，64声部I2S启动及稳定播放欠载均0。原实现目录保留，新位流尚未下载；新产物、哈希与本次证据见[Hold余量优化](verification/hold-margin-20261014/README.md)。以下日期记录保留各自验证时点。

2026-10-14（时序再优化）：采用两轮等价逻辑简化，Setup最小余量由0.051ns提高至0.272ns，Logic由22346减少至21968；Hold为0.035ns，仍偏紧。完整Gowin构建时序违规0，BSRAM仍106/118（约90%），时钟/引脚/约束与音源功能不变。核心33项由中断前28项与随后5项补跑的完整原始日志证明；watchdog和曲谱命令新增两组逐拍等价专项，共99,215拍通过。新源码已采用，原 `full/impl` 产物保留旧版；本次新位流、SHA256及全部证据见[时序余量优化](verification/timing-margin-20261014/README.md)。新位流尚未下载。重新跑Core可执行 `scripts/test-modelsim-full.cmd -Suite Core -TimeoutSeconds 1200`。

2026-10-14：修复手机首个NoteOn/最后NoteOff与断连释放同拍的边界问题，调整两份板级变量声明顺序与视频测试超时常量以兼容ModelSim。实际ModelSim核心33项全部通过，整机64声部和64声部I2S、MPR121、25灯点阵、控制/音效/视频均有日志与波形。当前输入哈希复核一致；额外双音源N64逐样本长测按用户选择暂缓，不能声明Full34项通过。最终源码完整Gowin构建通过，Setup/Hold违规0，最小余量0.051/0.065ns，BSRAM106/118（约90%），时序余量仍紧张。新位流在独立快照中，未下载；原实现产物保留。证据、位流及重跑步骤见[ModelSim核心回归与构建记录](verification/modelsim-20261014/README.md)。默认核心回归入口为 `scripts/test-modelsim-full.cmd`。

2026-10-13：按所选25灯WS2812B点阵和微雪ESP32-C3-Zero适配。点阵支持常量灯号映射和每通道亮度上限，绿色提示曲谱目标、蓝色显示实体触摸、重合为青色；映射默认保持DIN链序，实际空间顺序需到货校准。新增25键逐灯校准事件曲谱、映射生成工具和外部波形解码回归。C3使用微雪专用4MB/USB CDC目标，蓝牙桥会话隔离修正避免丢失连接后的首条指令。接线、校准和验证入口见[点阵与C3适配](hardware/led25/README.md)。新构建尚需单独完成下载和到货联调；下方2026-10-11实板记录对应旧位流。

2026-10-11：新增完整竞赛整合入口 **`full/ContestFull.gprj` / `board_contest_full_top`**，接入25键MPR121、四电极滑条、64声部四音色、运行时延迟/混响/合唱、脱机LED曲谱、演奏事件记录、手机控制和HDMI波形/频谱/XY显示。整机仿真和完整布局布线通过，建立/保持/复位相关时序违规均为0；原生Android APK已编译、lint零错误零警告并验证签名；ESP32-C3蓝牙桥固件已实际编译、退出码0、无警告。交付产物可用 `scripts/export-contest-full.ps1` 导出，记录源码与产物哈希。完整主工程已下载SRAM，用户码再次读回 `0x0000F0A6`；用户报告KEY0播放/停止/重播、KEY2复位恢复、KEY1停止及退出后重播通过，声音有音高变化但偏轻。记录见[主工程板上复测](docs/hardware/主工程板上复测-20261011.md)。官网延迟及手机/传感/LED/视频实物验收仍需完成。使用方法、接线和逐项证据见[全功能工程与官网验收](docs/全功能工程与官网验收-20261011.md)。下方为原发声里程碑与历史记录。

当前里程碑：**06 — 64声部音源与24位标准I2S输出**。内部与默认输出均为24位PCM，采用Philips I2S、每声道32位槽。DDS、ADSR、正弦/风琴/八成分钢琴音色、三维表情、混音和延迟均在FPGA内实现；FM电钢琴是可选音色。

2026-10-11工程复查：修正WS2812B-V5/W的高低脉宽与300µs锁存；手机拖动改为连续表达、40ms节流与最新值合并，增益/颤音不覆盖实体滑条弯音；旧连接上传/回传取消、曲谱快照、失焦释放与构建报告路径同步修复。专项与整机回归已通过，实际硬件延迟仍需测量。变更、验证与限制见[工程复查与优化](docs/工程复查与优化-20261011.md)。

2026-10-08（按键响应优化）：`boardkeys48/BoardInstrumentB48kI2S.gprj` 的演奏入口默认消抖等待由 10ms 降为 2ms。使用真实默认参数的专项仿真通过，三个测试时刻中输入引脚到首个完整非零 I2S 样本的最大响应为 2.292900ms，四声部、毛刺过滤与复位检查通过，欠载为 0；该结果属于数字仿真。新位流已生成、布局布线通过，尚未重新下载；实物机械弹跳和整机 ≤10ms 延迟仍需验收。修改、验证范围、位流哈希与复现步骤见[按键响应优化](docs/hardware/按键响应优化-20261008.md)。

2026-10-08：新增两个独立的 48kHz 外置 DAC 测试入口。当前实板 SRAM 下载的是 `boardseq16/BoardSequence16_48kI2S.gprj` / `board_sequence16_48k_i2s_top`：KEY0 启动 MIDI 60～75 的 16 个音逐个循环，每音按住 400ms，释放尾音结束后留出 100ms 静音间隔；KEY1 停止，KEY2 复位静音，同时最多一个声部。事件源及板级 I2S 仿真、布局布线和 SRAM 下载均通过（UserCode `0x0000EAF2`）；本版本实物试听反馈尚待确认，详见[16 音逐个播放测试](docs/hardware/16音逐个播放测试-20261008.md)。另保留 `board16/BoardAudio16_48kI2S.gprj` 的 16 声部同时发声测试，见[16 声部持续发声测试](docs/hardware/16声部持续发声测试-20261008.md)。两个入口均使用 FPGA HDL、同一 PCM5102A → PAM8403 → 无源喇叭链，不改变主音源的 64 声部能力。位流属于本地编译产物，GitHub 提供源码、ROM 和重建脚本；SRAM 配置断电后需重新下载。

2026-10-07：外置 PCM5102A → PAM8403 功放 → 无源喇叭的发声链已由用户完成试听。新增板载演奏工程 `boardkeys48/BoardInstrumentB48kI2S.gprj`，顶层 `board_instrument_b_48k_i2s_top`：KEY0 按住演奏钢琴 A4，KEY1 按住演奏 C 大三和弦，同时按两键为四声部，松开各自释放；KEY2 复位静音。该入口已接入 B 的 V2 输入边界和 A 的八成分钢琴，适配器/板级仿真与布局布线通过，SRAM 下载完成（UserCode `0x0000677B`），用户反馈试听“已完成”。新入口为 FPGA HDL；实体演奏面板及独立表情传感器仍待 B 交付。工程、验证范围与下一阶段交接见[板载按键演奏记录](docs/hardware/板载按键演奏-20261007.md)。下方日期记录保留当时状态。

2026-09-24：合入队员B的V2按键/和弦/表情输入与事件FIFO，新增统一逻辑顶层 `instrument_system_v2`，已接入当前含队员A八成分钢琴的音源。在 `AudioEngine_V2.gprj` 选择该顶层即可综合；`key_timbre/chord_timbre=2` 选择钢琴，设置顶层 `FM_ENABLE=1` 后可选音色3。复测入口为 `scripts/test-interaction.ps1`（Icarus）及 `scripts/test.ps1 -ModelSimBin <安装目录>`（ModelSim）。合并范围与验证见[队员B合并记录](docs/队员B合并记录-20260924.md)。统一逻辑顶层尚未接到实物键盘/传感器，不能直接作为板级烧录顶层；既有48kHz板级工程继续使用独立自检事件源。

2026-09-24：新增独立的 `clock48/BoardInstrumentB48kGAO.gprj`，用自动单音、和弦和表情事件验证队员B输入链、队员A钢琴音色与片内I2S。板级仿真和布局布线通过；新位流已下载至实板 SRAM，GAO 两次采集确认完成轮数循环变化、时钟锁定、I2S 非零且故障/欠载为零。实物键盘与DAC仍未接入。状态灯蓝色表示运行、绿色表示完成、红色表示故障。工程和上板状态见[队员B 48kHz板内自检](docs/hardware/队员B-48kHz板内自检-20260924.md)。

2026-09-23：合入队员A的四音区八成分钢琴音色（`event_timbre=2`），保留正弦/风琴及可选FM音色。音源的参数ROM和离线模型、仿真入口见[八成分分区钢琴](docs/八成分分区钢琴.md)，主工程验证见[合并记录](docs/队员A八成分合并记录-20260923.md)。当前板级Live64自检仍固定使用原音色，原有GAO/I2S位流也尚未按新音源重编译；要听到新钢琴音色，需后续加入可选择音色的事件输入、重编译并连接外置DAC验证。主工程保留已修复启动欠载的I2S发送器。

2026-09-23：新增独立 `clock48/BoardAudio48kI2S.gprj`，把既有64声部与49.152MHz时钟接到PMOD1候选引脚，输出标称48kHz、24位标准I2S。启动、停止、再次启动与复位仿真及布局布线已通过；外部DAC已到货但尚未接线，引脚方向和模拟输出尚未实测。原GAO入口和位流保持不变。见[48kHz外置I2S预备工程](docs/hardware/48kHz外置I2S预备工程-20260923.md)。

2026-09-23：新增独立 `clock48/BoardAudio48kGAO.gprj` 板级验证入口，底板50MHz经两级PLLA生成标称49.152MHz音频时钟。实物SRAM下载后，三份4096点GAO采集均通过48kHz频率比与24位标准I2S时序检查，64声部运行时错误、故障及欠载为0。前两次采集之间的配置变化原因尚未查明；已知断电重接后的第三次采集经重新下载恢复。外置DAC尚未接入。见[48kHz板级验证记录](docs/hardware/48kHz时钟与I2S板级验证-20260923.md)。

启动欠载已增加首样本预备状态修复，播放期间仍检测真实缺帧；同时将GAO自检复位改为寄存器输出。新版已SRAM下载，两次实物采集64声部、欠载/错误/故障均为0，自动启停15→80轮。见[启动欠载修复](docs/hardware/启动欠载修复-20260923.md)。

2026-09-23：新增 `BoardAudioGAO.gprj`，已完成SRAM下载和两次实物GAO采集：64声部运行，自动启停完成次数从29增至120，错误/粘滞故障均为0；内部24位标准I2S时序检查通过。外置DAC及模拟输出仍待验证。见[GAO板内验证记录](docs/hardware/GAO板内验证-20260923.md)。

2026-09-22：新增 `BoardAudioDiagnostic.gprj`，顶层 `board_audio_diagnostic_top`，已把板级按键和状态灯接入既有64声部主音源，供DAC到货前做数字自检。采用50MHz，实际采样率48,828.125Hz；还不是最终48kHz外接DAC发声入口。已完成布局布线，保留PR1014时钟布线警告；实物验收尚待完成。见[主音源板级接入](docs/hardware/主音源板级接入-20260922.md)。独立 `BoardBringup.gprj` 保留用于基础按键/灯光排查，详见[板级验证记录](docs/hardware/板级验证-20260922.md)。

2026-09-19最终选择：工程仅保留24位标准Philips I2S输出，已移除PT8211模式参数、发送分支及专用测试脚本。干声和延迟顶层使用同一标准I2S接口，需连接支持该格式的DAC；不能直接驱动仅支持LSBJ的PT8211。参见[标准I2S恢复记录](docs/恢复24位标准I2S-20260919.md)。

当前音频工程为 **`AudioEngine_V2.gprj`**，默认使用干声顶层 **`audio_system_v2`**；需要50ms反馈延迟时选择`audio_system_v2_delay`。合并与验证说明见[音源合并记录](docs/音源合并记录-20260918.md)，详细算法见[音频引擎V2实现与接线](docs/音频引擎V2实现与接线.md)。

2026-09-19已增量合入队员A的64音现场自检：在GOWIN打开 `Live64_Diagnostic.gprj` 并选择 `live64_system_top` 顶层，可使用原音源生成64个不同音高并通过24位标准I2S输出。它是独立诊断入口，正常演奏顶层与公共V2接口保持不变；自检切入正常演奏系统时仍需实现事件入口独占与尾音回收。见[自检接入说明](docs/64音现场自检与接入.md)和[本次合并验证记录](docs/Live64合并验证-20260919.md)。

公共接口沿用[接口V2与队员迁移](docs/接口V2与队员迁移.md)。`TangMega60K_Synth_V2.gprj` / `captain_system_top_v2`继续保留作为队长控制与I2S接口工程，不包含完整音源。

第三阶段入口：[测试音源、波形与试听说明](docs/第三阶段-测试音源.md)。独立诊断工程为 `ToneDemo.gprj`，不会替换队友对接顶层。

当前已有可烧录发声的板载按键演奏入口，完整实体演奏面板和独立表情输入仍待集成。
目标器件为 GW5AT-60B / GW5AT-LV60PG484AC1/I0；对应 Sipeed Tang Mega 60K。
板级数字自检已有底板引脚约束和SDC；标称48kHz音频时钟已在独立GAO工程中完成板内验证。PMOD1 外置 DAC 已接线并发声；实体键床和独立表情输入仍待到货联调，踏板尚未接入。`audio_system_v2` 接收内部事件/表情接口，不能直接作为板级引脚顶层烧录；当前整机演示使用 `full/ContestFull.gprj`，旧按键演奏入口保留于 `boardkeys48`，外置发声自检保留于 `clock48/BoardAudio48kI2S.gprj`，片内数字验证入口保留于 `clock48`。

## 从哪里开始

1. 完整工程源码入口是 `full/ContestFull.gprj`，顶层 `board_contest_full_top`。若要重建本版已验证位流，请先解压上方滑条音量ZIP，使用其中`fpga-source/full/ContestFull.gprj`及配套说明，保证GAO开关与冻结输入一致。旧`full/impl`及下方历史位流不自动代表本版。当前未下载，实物操作可参考[首次上板步骤](docs/全功能首次上板步骤-20261011.md)，并按当前CST与[本版操作](docs/滑条音量模式使用说明_20261026.md)核对。独立音源开发可打开`AudioEngine_V2.gprj`/`audio_system_v2`，单独控制开发可打开`TangMega60K_Synth_V2.gprj`。
   16 个音逐个播放打开 `boardseq16/BoardSequence16_48kI2S.gprj`，选择 `board_sequence16_48k_i2s_top`；在项目根目录用 GOWIN 的 `gw_sh` 执行 `scripts/build-board-sequence16-48k-i2s.tcl`，生成 `boardseq16/impl/pnr/BoardSequence16_48kI2S.fs` 后下载至 SRAM。事件源和完整板级仿真分别运行 `scripts/test-sequence16-event-source.ps1`、`scripts/test-board-sequence16-48k-i2s.ps1`。
   当前板载按键演奏打开 `boardkeys48/BoardInstrumentB48kI2S.gprj`，选择 `board_instrument_b_48k_i2s_top`；下载 `boardkeys48/impl/pnr/BoardInstrumentB48kI2S.fs` 到 SRAM，断电后需重新下载。
   既有64音48kHz数字验证打开`clock48/BoardAudio48kGAO.gprj`；验证队员B输入链打开`clock48/BoardInstrumentB48kGAO.gprj`。两者仅在片内采集I2S，尚无外置DAC引脚。
   外置 I2S 自检打开 `clock48/BoardAudio48kI2S.gprj`，接线与发声记录见 `docs/hardware/外置I2S下载验证-20261007.md`。
2. 完整音频连接见`rtl/audio/audio_system_v2.v`；其内部实例化原`rtl/captain_system_top_v2.v`及A的`voice_engine`。这些都不是物理板级顶层。
3. 第二阶段先看 `docs/第二阶段-I2S使用说明.md`，再看 `rtl/i2s_tx.v`。
4. `sim/tb_i2s_tx.sv` 用模拟样本源和独立串行接收器验证第二阶段，不需要板子或队友代码。
5. 第一阶段继续保留：`rtl/voice_allocator.v`、`sim/tb_voice_allocator.sv` 与 `docs/接口与第一课.md`。
6. 队员B按V2接口接入`event_*`和`expr_*`；64个逻辑声部已在音源内混成左右两个输出声道。所有模块共用音频系统时钟，默认要求49.152MHz以输出48kHz音频。

## ModelSim 显示波形

2026-10-14整机核心回归已保存的波形及默认33项验证入口见[本次记录](verification/modelsim-20261014/README.md#重跑与查看)。下面保留原独立音源与I2S的波形入口。

当前64声部标准I2S音源可在Transcript执行以下命令，自动编译、运行自检并打开Wave；结束后保留窗口：

```tcl
cd {C:/Users/asus/Desktop/Git/TangMega60K_Synth}
do sim/waves_audio_v2.do
```

请替换为自己的工程路径。脚本通过后自动保存波形、布局和摘要，每次结果独立放在 `sim/audio_results/gui_时间戳_编号/`。重新测试只需再次执行 `do sim/waves_audio_v2.do`。结果与波形阅读方法见[ModelSim波形检查](docs/ModelSim波形检查-20260918.md)。

查看已有Live64波形时，按[加载说明](docs/Live64合并验证-20260919.md#已保存波形的加载)设置 `live64_project_root`，再执行 `do "$live64_project_root/sim/view_live64_wave.do"`。脚本选择最新的已完成记录，以明确路径加载 `checked.wlf`。波形产物不随Git上传，新克隆须先获得本地仿真结果。以下是原第二阶段独立I2S接口测试的查看方式。

在 ModelSim Transcript 输入（使用当前项目的独立 work 库）：

```tcl
cd {D:/your-workspace/git/TangMega60K_Synth/sim}
do waves_i2s.do
```

脚本运行前110 us，并放大到41～64 us附近，查看第一个非零左右声道样本。
请将示例路径替换为你自己电脑的实际目录。要继续执行完整测试，在 Transcript 输入 `onfinish stop; run -all`；出现 `ALL I2S TESTS PASSED` 后停在 `$finish` 是正常结束。
左声道为 `7fffff`，右声道为 `800000`。操作和波形含义见第二阶段说明。
若要回看第一阶段，将最后一行换成 `do waves.do`。

`active_count` 包括按住与释放尾音占用的声部，不等于当前可闻振荡器数量；
计分仍需实际板卡上验证同时可闻的振荡器数量和输出采样率。

## 自动验证

在项目根目录的 PowerShell 中运行：

```powershell
# 原控制/I2S的六组回归
./scripts/test-iverilog.ps1

# 完整音源单元、4/64声部、I2S和PCM分析（路径改成自己的安装目录）
./scripts/test-audio.ps1 -ModelSimBin 'D:/msim/modelsim_ase/win32aloem'
```

脚本默认寻找C盘ModelSim，实际安装位置通过`-ModelSimBin`指定。本机另提供`./scripts/test-iverilog.ps1`，默认寻找`C:\iverilog\bin`，也可用`-IcarusBin`指定。
使用项目自己的 `sim/modelsim_local.ini`，不修改之前配置的共享 GW5A 库。
原V2音源RTL没有例化高云原语；独立48kHz板级工程使用Gowin PLLA及其仿真模型，验证方法见[48kHz板级验证记录](docs/hardware/48kHz时钟与I2S板级验证-20260923.md)。
原控制回归脚本依次验证V1分配、V1 I2S、测试音源、V2控制、V2 I2S、V2兼容六组。V2通过标志是`ALL V2 CONTROL TESTS PASSED`、`ALL V2 I2S TESTS PASSED`和`ALL V2 LEGACY TESTS PASSED`。Icarus结果在`sim/iverilog_results/`。原WAV导出脚本读取`sim/tone_samples.csv`，不会自动读取Icarus新目录；不要将旧CSV当作新测试结果。

GOWIN仅综合：

```powershell
& 'C:/Gowin/Gowin_V1.9.12_x64/IDE/bin/gw_sh.exe' scripts/synth.tcl
```

V2使用同目录的`scripts/synth-v2.tcl`，单独生成V2综合报告。

完整音频工程的综合命令（从工程根目录执行）：

```powershell
& 'C:/Gowin/Gowin_V1.9.12_x64/IDE/bin/gw_sh.exe' scripts/synth-audio.tcl
# 可选：开启延迟的顶层；该运行会覆盖同一impl目录内的综合报告
& 'C:/Gowin/Gowin_V1.9.12_x64/IDE/bin/gw_sh.exe' scripts/synth-audio-fx.tcl
```

ROM数据已随源码提供；更改采样率时必须同步调整时钟、引擎参数和ROM生成配置。仿真CSV是验证输出，不是板上发声音源。

## 已实现的策略

- 最低编号空闲声部优先。
- V1按音符编号识别；V2按`(event_source,event_note)`识别。同一来源仍按住的相同音符重触发复用声部，不同来源的同音独立分配和释放。
- 松键后发送release命令；收到引擎的完成握手才释放槽位。
- 同音符旧尾音仍在释放时再次按下：另取空闲槽位。
- 满载的新音符被拒绝，同时输出 `full_pulse`；不硬切尾音。
- 未按下音符的松键事件忽略；力度0的note-on按note-off处理。
- 引擎未准备好时，命令内容保持稳定，输入通过ready反压。
- 接口暂定1～64个声部，ID_WIDTH必须能表示声部编号；当前工程为64/6。

## 下一阶段

三人协作、提交范围与合并步骤见 [团队协作说明](docs/团队协作说明.md)。

1. 队员A的音源已经接入，继续做上板音质、音色切换及64声部频谱验证。
2. 队员B按V2说明接入25键扫描、力度、来源编号、表情快照和事件FIFO；共同定义延音踏板及全音停止语义。当前同一来源仍按住的同音高重触发会复用声部，不能仅延后note-off就声称支持踏板下同音无限叠加。
3. 核对实际 NEO Dock 版本、原理图和 DAC 要求，建立音频时钟及复位，补齐板级顶层、CST/SDC。
4. 完成布局布线和时序检查后再上板；测实际发声、64频率谱峰及传感器到音频输出延迟。

官方资料：
- https://wiki.sipeed.com/hardware/zh/tang/tang-mega-60k/mega-60k.html
- https://github.com/sipeed/TangMega-60K-example/tree/main/audio_i2s

注意：检查时官方 `audio_i2s` 目录只有标记TBD的README，不能将它当作已经提供的完整音频工程。
