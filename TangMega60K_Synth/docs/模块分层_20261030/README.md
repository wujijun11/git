# 弦光工程模块分层与Flash更新说明

整理日期：2026-10-30。对象：本地延音测试分支codex/sustain-20261030，基于Chord F571。
本文按当前文件和实例关系说明职责，不重排源码、不改变算法、不重新构建、不烧录。
发布方式为独立测试分支；最初本地交付时的“未上传”状态按对应记录日期理解。

## 先确认这次的Flash配置

你已反馈Flash启动问题修复。在同一板卡和Flash上更新本次延音位流，沿用这次成功的配置，
更换FS File即可。这里没有获得你最终成功配置的完整截图，因此不能替你断言实际Flash芯片型号。

| Programmer项目 | 应采用的设置 |
|---|---|
| Device | GW5AT-60B；Part Number为GW5AT-LV60PG484AC1/I0，Version B。 |
| Access Mode | External Flash Mode，使用已经成功的外部Flash写入配置。 |
| Operation | 官方推荐exFlash Erase, Program through GAO-Bridge Arora V（1.9.12及以上）；旧工具对应5A。继续沿用本次成功的GAO-Bridge操作。 |
| Flash型号、容量、地址及启动拨码 | 同一硬件保持本次成功值；不要因更新音色/延音就随意更换。新位流文件头启动地址为0。 |
| Cable / Port | 使用当前实际检测到的下载器；重新插USB后编号可能变化，不照抄历史801。 |
| Frequency | 沿用已成功速率；此位流LoadingRate为2.500MHz。它不是49.152MHz工作时钟或48kHz采样率。 |
| FS File | delivery-sustain/fpga/ContestFull_ChordSustain_TEST1024.fs；UserCode为0x00007D2F。 |

下载动作显示Finished后，用RECONFIG或重新上电检查是否真正从Flash启动。
SRAM Program仍只是临时配置；它不是写Flash。新文件会更新对应Flash配置区，原F571备份保留在独立最终版目录。
本次没有操作下载器，也没有把用户修复旧Flash启动的反馈等同于新延音功能已经上板通过。

官方依据：[Sipeed Tang Mega 60K说明：Getting Started及How to burn the bitstream to FLASH](https://wiki.sipeed.com/hardware/en/tang/tang-mega-60k/mega-60k.html)。

## 把整个乐器看成一条工作流程

```text
人的手                     电脑/手机曲谱与控制
  ↓                               ↓ BLE
MPR121触摸模块                  ESP32-C3桥接固件
  ↓ I2C                           ↓ UART
触摸采集、按下/松开识别       通信帧校验与命令分发
  └─────────────┬─────────────────┘
                ↓
     菜单/表情设置、曲谱录放与学习
                ↓ 音符事件 event_*
           公平仲裁 → 事件队列
                ↓
      64声部分配 → 延音门 → 音源命令 cmd_*
                ↓               ↑ done_*回收声部
      DDS/八成分钢琴/FM、包络、音量
                ↓
          立体声混音、峰值保护
                ↓
          音效、短提示音 → I2S → DAC → 功放 → 喇叭
                │
                └─ 状态/样本观察 → OLED、HDMI、5×5灯板
```

这里的箭头表示数据关系，并非所有模块轮流用一个软件CPU执行。
FPGA中的驱动、通信、显示、音源等电路同时工作；音源内部再按固定时序分时扫描64个逻辑声部。
每个逻辑声部保存自己的相位、音高、包络及音色状态。八个泛音分量和64个逻辑声部也不是同一个计数概念。

## 九个层次分别管什么

| 层 | 小白理解 | 主要文件/目录 | 责任边界 |
|---|---|---|---|
| 总装与启动 | 把各零件接起来，并让它们按正确顺序启动 | rtl/board/board_contest_full_top.v、rtl/instrument_full_system.v、board_bringup_top.v、audio_boot_status.v | 顶层负责连接；不是把所有算法写在这里。 |
| 时钟 | 给电路统一节拍 | rtl/clock/ | 50MHz板载参考转换为49.152MHz音频时钟；视频另有时钟。 |
| 输入驱动 | 问传感器“现在按着哪几个键、滑条在哪” | rtl/sensors/ | 三组MPR121及I2C；收到前2字节先上报琴键，其余数据随后读完。 |
| 通信与控制 | 把滑条、按键和远程操作变为明确指令 | rtl/control/、rtl/remote/ | 菜单、移调、表情、CRC/ACK、断连释放；不计算声音波形。 |
| 曲谱与学习 | 决定何时弹什么、记录刚才弹了什么 | rtl/performance/ | 保存音符事件、节拍、学习等待和停止释放，不保存整段录音。 |
| 声部管理 | 为每个音安排“发声位置” | event_fifo_v2、captain_control_top_v2、voice_allocator_v2、sustain_command_gate | 排队、分配64槽、暂缓松键、等待done回收；不决定钢琴泛音配方。 |
| 音频计算 | 算出这一瞬间扬声器应有多大振幅 | rtl/audio/ | 音高、相位、包络、八成分钢琴/FM、立体声混音、限幅及音效。 |
| 声音输出 | 把两路数字振幅按DAC能理解的顺序送出去 | rtl/i2s_tx.v | 左右24位有符号PCM，标准Philips I2S，每声道32位槽、48kHz。 |
| 可视化 | 让人看见状态、波形或下一步目标 | rtl/visual/、rtl/performance/ws2812_guide.v | OLED、HDMI、灯板观察功能；不允许显示刷新拖住音源。 |

“分层”是职责上的分法。现在control里有新延音门、audio/rom里有菜单字模等历史路径，
不代表它们的职责混在一起。为保持GPRJ、ROM读取和脚本路径有效，本轮只整理说明，不移动文件。

## 三种程序分别运行在哪里

| 运行位置 | 源码 | 包含的层次 | 安装/加载对象 |
|---|---|---|---|
| FPGA | rtl/及工程/约束/ROM | 可综合硬件、状态RAM与接口电路 | Gowin构建出的.fs |
| ESP32-C3 | firmware/ble_bridge/ | BLE服务、连接策略、UART桥接 | C3固件；本次延音没有改它 |
| Windows | desktop/ | 界面、控制业务、协议、曲库/MIDI处理、偏好存储、原生后台调度及BLE宿主 | EXE与配套_internal文件夹 |
| Android | mobile/web/、mobile/android/ | 界面与业务、MIDI处理、Java BLE驱动与宿主 | APK |

Windows的重要对应关系：web/app.js接界面，web/controller.js管理业务，web/protocol.js编码帧，
native_host.py管理本地窗口/连接，ble_link.py管理BLE性能策略，preferences.py保存偏好，
score_library/负责搜索推荐与MIDI转换，realtime_native/负责后台实时曲谱调度。
Windows最小化播放不依赖页面计时器逐音发送；手机原生桥接在mobile/android/app/src/main/java/cn/tangsynth/remote/。

Android的MainActivity是界面宿主和原生桥接入口；Protocol处理帧，BlePerformanceLink处理BLE性能请求，
MusicCatalog和MusicRecommendations处理曲库数据。这里只说明现状，并不声称每处原生代码都已完全拆分。

上位机上传的是“某时刻按下/松开哪个音”的事件，不是PCM音频。上传到板内的一首曲谱目前最多1024条事件；
Windows蓝牙实时播放则把曲谱留在电脑逐条发送，容量和停止条件另由实时播放模块约束。

## 一个键从按下到出声经过哪里

1. mpr121_sampler通过i2c_register_master读取触摸芯片；mpr121_key_eventizer识别按下/松开。
2. 当前键位映射和音区决定MIDI音高，note_arbiter合并实体键、远程键和曲谱事件，event_fifo_v2排队。
3. captain_control_top_v2中的voice_allocator_v2为音符选择一个声部编号，发出cmd_*。
4. sustain_command_gate转发按下；延音打开时暂存已松键声部的OFF，关闭延音再发送这些OFF。
5. voice_engine读取voice_state_ram，算音高与相位；polar_lane产生钢琴分量，adsr决定按下和松开时的音量变化。
6. stereo_mixer把声部相加，gain_saturator应用总增益，stereo_peak_limiter按真实峰值保护。
7. runtime_audio_fx计算已选音效，ui_tone_overlay叠加短提示音，i2s_tx把左右PCM送给PCM5102。
8. 声部释放完成时done_*返回分配器，槽位才可重新分配；延音保留的尾音仍占声部。

同一音频帧全部声部使用同一份表情参数快照；expression_controls_v2在engine_sample_begin边沿提交，
音源下一边沿或之后读取新值，pitch_expression负责实际增益/变调/颤音和必要平滑。
这个“表情平滑”和已停用的“按声部数变化的混音增益平滑”是两件事。

## 工程、约束、ROM与历史目录

| 路径/类型 | 用途 |
|---|---|
| full/ContestFull.gprj | 完整工程文件清单，不是HDL算法本身。发布脚本显式指定board_contest_full_top为顶层。 |
| full/contest_full.cst | 信号到板上引脚及电平的绑定；更换引脚需要核对它并重新构建。 |
| full/contest_full.sdc | 时钟、跨时钟与时序检查约束，不是一个可以随意调大掩盖问题的延迟参数表。 |
| full/main_status.rao | GAO调试配置。本次交付通过--without-gao隔离构建，冻结source工程禁用GAO；开发工作区原条目仍保留。 |
| rtl/audio/rom/ | 正弦表、音高频率字、钢琴幅度/相位与衰减等参数，以及菜单字模；不是整段PCM录音。 |
| rtl/visual/goertzel_1024_64.hex | HDMI频点观察系数。显示频点数不等于独立振荡器数量。 |
| full/之外的board16、boardkeys48、boardseq16、mono_auto、mono_diag、clock48等 | 独立调试或历史工程；不能只看“文件更新日期”选择烧录对象。 |
| examples/ | 接线/模块调用示例，不能当作已接入完整顶层的功能。 |
| sim/ | 测试台、参考电路与波形配置；测试台有不可综合语句，不下载到板上。 |
| scripts/ | 构建、测试、分析、ROM/字模离线生成和交付打包；不在FPGA运行。 |
| docs/、docs/reports/ | 原理、接口、问题记录及对应版本的证据。旧文档的状态要按日期理解。 |
| hardware/ | 键盘、滑条、转接/电平转换等PCB设计与CAD辅助代码，不属于FPGA位流。 |
| licenses/、firmware/libraries/ | 字体/第三方BLE库许可及来源。 |
| releases/、delivery-* | 交付副本，不是继续开发时随意修改的源目录。 |
| verification/、tmp/ | 构建输出、验证运行目录、依赖和临时文件，不作为主源码重复学习。 |

要在GUI查看与新位流对应的冻结输入，打开delivery-sustain/source/full/ContestFull.gprj。
重新运行构建仍以隔离构建脚本的顶层/选项为准，不把工作区的GAO状态当作发布位流配置。

## 阅读入口与验证边界

- [FPGA模块逐文件说明](FPGA模块逐文件说明.md)：当前工程每个HDL文件、模块名、职责及备用入口。
- [全部源码文件分类](全部源码文件分类.md)：Windows、手机、C3、测试、工具和硬件脚本逐文件用途。
- [机器可读模块清单](模块清单.json)：文件SHA256、所属层和直接实例关系，可核对本次文档输入。
- [本次整理实现说明](本次整理实现说明.md)：清点范围、发现的问题、解决方式和实际执行的检查。
- [逐模块输入输出](../模块输入输出_20261030/README.md)：输入/输出、位宽、单位、握手和连接示例。

本轮只做文档和静态一致性核对，没有重复运行ModelSim/Gowin。延音原有验证见同级上一层的
开关式延音与蓝牙控制实现说明_20261030.md及reports/sustain-20261030/analysis.json。
新延音上板听感、真实BLE、长时间运行仍待实测；已有OLED基本正常的用户反馈不等于新增延音页面全部验收。
5×5灯板的实际映射、指引与新版本联合运行也不能凭仿真宣称通过。

Flash状态追加：2026-10-30用户确认已修复启动问题，具体修复方法未提供；记录为用户实测反馈，不编造根因。
原交付包保持不变，本文作为新增补充说明，未重写其中封存的校验清单。

本次清点数量：desktop 67个，examples 1个，firmware 65个，hardware 39个，mobile 31个，mono_auto 1个，mono_diag 2个，rtl 90个，scripts 155个，sim 145个。
