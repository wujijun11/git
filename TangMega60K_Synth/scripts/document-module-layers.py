"""按当前工作区生成模块分层说明；只写文档，不编译、不烧录、不移动源码。

使用原有源码清点器解析模块实例。静态关系包含 generate 的所有分支，
因此只能用于阅读导航，不能代替综合裁剪、资源报告或硬件验证。
"""
import collections
import hashlib
import importlib.util
import json
import re
import subprocess
import sys
import xml.etree.ElementTree as ET
from pathlib import Path
from urllib.parse import quote

ROOT = Path(__file__).resolve().parents[1]
OUTPUT = ROOT / "docs/模块分层_20261030"
CODE_EXTENSIONS = {
    ".v", ".sv", ".ino", ".cpp", ".h", ".c", ".py", ".js", ".cjs",
    ".java", ".ps1", ".cmd", ".tcl", ".do", ".html", ".css", ".gradle",
}
EXCLUDED = ("docs/", "verification/", "releases/", "tmp/", "delivery-", "assets/")

# 补齐旧清单之后新增或改变职责的文件，不能直接沿用旧版本的用途说明。
PURPOSES = {
    "rtl/control/sustain_command_gate.v": "开关式延音：位于原分配器与音源之间，记录已松键但暂不释放的声部；关闭延音逐个发送OFF，反压期间保持命令。",
    "rtl/control/menu_hierarchy.v": "当前分层菜单：声音、表情、录放、曲谱；声音页含延音入口。普通设置后显示波形，闲置10秒显示波形，之后触摸回音量。",
    "rtl/control/slider_gesture_input.v": "把滑条位置拆成短触、左端长按、右端长按和连续控制位置；含消抖、区域迟滞及事件反压保持。",
    "rtl/control/slider_expression_control.v": "把连续位置映射为音量0..2048、弯音±200音分或颤音0..100音分；只更新选中字段，已呈现命令不被覆盖。",
    "rtl/control/slider_menu_controller.v": "旧版平面四页菜单控制器；当前分层菜单开启时不会选择此generate分支，保留兼容与测试。",
    "rtl/control/slider_volume_control.v": "单独的滑条音量映射；当前分层菜单采用slider_expression_control，此模块用于关闭分层菜单后的兼容分支。",
    "rtl/control/remote_command_router.v": "将校验后的命令分发为音符、表情、配置、曲谱操作和状态查询；含ACK及重试去重。新延音使用CONFIG目标2和READBACK选择器5/状态0x86。",
    "rtl/audio/headroom_smoother.v": "旧方案：平滑按活跃声部数选择的混音增益；当前STABLE_CHORD_GAIN=1先选择固定增益分支，因此此平滑分支未启用。",
    "rtl/audio/stereo_peak_limiter.v": "当前和弦峰值保护：根据实际PCM峰值联动限制左右声道，快速压低、逐帧恢复；不因第二个音出现就固定减半。",
    "rtl/audio/gain_saturator.v": "施加Q1.11总增益，输出宽位中间结果和24位饱和值；当前固定增益分支将宽位结果交给峰值保护，避免提前截断。",
    "rtl/audio/audio_fx.v": "早期固定延迟/旁路包装；完整工程设置FX_ENABLE=0走旁路，实际可切换效果由runtime_audio_fx承担，并非两套延迟同时开启。",
    "rtl/board/audio_boot_status.v": "在50MHz域观察PLL、复位、音频心跳和传感器状态，控制板载RGB诊断色；不接入音频ready/reset控制链，不保存黑匣子历史。",
    "rtl/visual/oled_hierarchy_renderer.v": "按当前分层页面、四区域、参数单位和延音实际状态生成OLED字节；由字模生成器和模板生成。",
    "rtl/visual/oled_i2c_stream.v": "OLED专用开漏I2C写流，处理ACK、时钟延展、卡线恢复和超时；独立于三组触摸I2C，不阻塞音源。",
    "rtl/visual/oled_idle_view.v": "OLED兼容显示覆盖层：根据空闲时间选择波形显示，不执行菜单动作；当前分层菜单主要通过外部waveform_view决定显示。",
    "rtl/visual/oled_wave_capture.v": "捕获实际发送的左声道PCM，每4个样本形成一列，128列共约10.667ms；双缓冲保存每列上下界，显示不反压音频。",
    "rtl/visual/oled_wave_renderer.v": "将采样上下界画为OLED下方48像素的动感波形，保留上方模式标题；仅改变显示，不生成声音。",
    "rtl/performance/performance_controller.v": "曲谱/录制RAM、时间调度、播放、停止释放、指引与学习的业务核心；当前板上曲谱容量1024条事件，不是1024首歌，也不保存PCM。",
    "rtl/remote/remote_uart_transport.sv": "包含remote_uart_rx、remote_uart_tx及传输包装：UART收发、16字节通信帧、CRC和队列。通信帧V1编号与内部控制V2编号相互独立。",
    "desktop/web/app.js": "Windows页面初始化、界面交互和显示刷新；延音勾选以实际回读为准。业务和通信委托给独立模块，界面不进行音频合成。",
    "desktop/web/controller.js": "Windows控制业务：握手、能力探测、事务队列、状态读取和延音控制；通过协议与原生主程序通信。",
    "desktop/web/protocol.js": "Windows通信帧、CRC、字段编码/解析；含延音配置与严格状态检查，不生成PCM。",
    "desktop/native_host.py": "Windows本地窗口与BLE/串口字节传输宿主；协调前端、曲库和原生播放会话，实时播放租用BLE线程，避开最小化后的页面计时限制。",
    "desktop/realtime_native/__init__.py": "Windows原生实时曲谱播放包入口。",
    "desktop/realtime_native/player.py": "使用单调时钟调度已转换的音符事件、NOTE/ACK与长休止保活；曲谱留在电脑，发声仍由FPGA实时合成。",
    "desktop/realtime_native/protocol.py": "原生后台播放器的16字节帧、CRC及ACK会话；租用既有连接，不另建一条相互竞争的BLE连接。",
    "desktop/web/native-score-player.js": "前端到原生后台播放器的适配器，负责启动/停止与显示进度，页面计时器不负责真实BLE音符发送。",
    "desktop/tests/probe_minimized_window.py": "Windows真实窗口最小化专项探针；使用内存设备的结果不能等同真实BLE或板卡实测。",
    "desktop/tests/test_native_lease.cjs": "验证前端与原生播放会话的租用/归还和旧会话隔离。",
    "desktop/tests/test_native_playback.py": "验证原生后台播放器的顺序、时序调度、停止、保活及错误处理，使用测试替身。",
    "desktop/tests/test_sustain.js": "验证新延音命令、能力探测、状态解析及旧固件降级。",
    "desktop/tests/test_sustain_ui.cjs": "验证桌面延音复选框的真实界面与回读行为，使用模拟板端。",
    "mobile/web/app.js": "手机页面初始化、交互与实际状态展示，含延音开关；通过Android原生BLE桥接控制FPGA。",
    "mobile/web/protocol.js": "手机端16字节帧、CRC及字段编解码，含延音扩展；不把音频送入FPGA。",
    "scripts/document-module-layers.py": "本次模块分层文档生成器：读取工作区、工程清单和实例关系，生成用途/职责索引，不改RTL、不烧录。",
    "scripts/document-module-interfaces.py": "提取97个RTL模块的端口、参数和实际命名接线，校验解析边界并调用独立文档渲染模块。",
    "scripts/module_docs/__init__.py": "接口学习文档工具包入口，不参与FPGA综合。",
    "scripts/module_docs/interface_meanings.py": "人工核对的端口中文含义、单位和同名端口特例；与声明解析分离。",
    "scripts/module_docs/interface_guides.py": "模块时序、握手与编译参数单位说明，不按名字臆造固定延迟。",
    "scripts/module_docs/render_interfaces.py": "把已核对的端口和实例数据输出为分层接口表、入门说明及连接索引。",
    "scripts/catalog-submission-sources.py": "按指定Git提交只读清点源码及静态实例关系；本次仅复用其解析函数，实际输入为当前延音工作区。",
    "scripts/render-source-guide.py": "将作品源码清点结果与用途说明整理为可阅读文档，不参与板内实时运算。",
    "scripts/generate-hierarchy-font.py": "离线从合法字体生成分层菜单字模和渲染器；不是运行时软件音源。",
    "scripts/estimate-fixed-gain.py": "离线评估固定混音增益与峰值余量，为和弦音量方案提供数据。",
    "scripts/analyze-chord-touch.py": "分析和弦固定增益及触摸提前上报的仿真数据和构建报告。",
    "scripts/analyze-headroom-smoothing.py": "分析旧版分档混音增益平滑实验；此脚本存在不表示当前启用该算法。",
    "scripts/analyze-hierarchy-oled.py": "分析分层菜单、表情与OLED仿真及构建结果。",
    "scripts/analyze-oled-wave.py": "分析OLED空闲波形捕获与显示实验结果。",
    "scripts/analyze-sustain.py": "核对新延音的仿真、PCM中性对照、时序、资源与受保护基线文件。",
    "scripts/collect-sustain.py": "收集延音验证证据和真实构建输入，保留失败与修正记录。",
    "scripts/package-sustain.py": "打包延音位流、冻结源码、客户端及验证证据并生成校验清单，不执行下载。",
    "scripts/verify-sustain.ps1": "执行延音4/64声部核心用例、基线回归与隔离Gowin构建的专项入口。",
    "scripts/verify-sustain-clients.py": "执行桌面/手机协议、界面和原生桥接验证并归档日志；测试替身不代表真实蓝牙。",
    "scripts/verify-chord-touch.ps1": "运行固定增益和弦与触摸提前上报专项，收集ModelSim和构建结果。",
    "scripts/verify-headroom-smoothing.ps1": "旧版分档增益平滑专项验证入口；不是当前固定增益方案的启用开关。",
    "scripts/verify-menu-hierarchy.ps1": "运行分层菜单、表情及OLED联动验证并收集证据。",
    "scripts/verify-oled-idle-wave.ps1": "运行OLED空闲实时波形相关仿真与构建验证。",
    "scripts/verify-slider-idle10.ps1": "运行滑条10秒空闲进入波形相关验证。",
    "scripts/verify-windows-minimized.ps1": "Windows最小化后台曲谱专项验证与打包入口，不修改FPGA音源。",
    "scripts/test-headroom-analysis.py": "验证旧平滑方案分析脚本对输入数据和异常结果的判断。",
    "sim/performance_held_write_reference.v": "冻结的曲谱按住状态写入参考电路，只用于等价对照，不进入当前位流。",
    "sim/tb_audio_boot_status.sv": "验证PLL/复位/心跳等启动状态对应的RGB诊断输出。",
    "sim/tb_headroom_smoother.sv": "验证旧分档增益平滑模块的步进、峰值保护和边界。",
    "sim/tb_headroom_smoothing.sv": "旧混音平滑方案的系统音频对照测试，不表示当前启用该分支。",
    "sim/tb_menu_hierarchy.sv": "验证分层菜单导航、10秒空闲、设置后波形和表情切换。",
    "sim/tb_mpr121_early.sv": "验证收到前两个按键状态字节后提前上报，同时继续完成后续传感器读取。",
    "sim/tb_oled_hierarchy.sv": "验证分层菜单OLED像素和文字输出。",
    "sim/tb_oled_i2c_stream.sv": "验证OLED写流、ACK/超时和卡线处理。",
    "sim/tb_oled_idle10.sv": "验证10秒空闲显示切换与触摸恢复规则。",
    "sim/tb_oled_wave_board.sv": "验证完整板级包装中的OLED波形采样与显示连接。",
    "sim/tb_oled_wave_display.sv": "验证OLED波形显示与模式标题组合。",
    "sim/tb_oled_wave_units.sv": "验证波形捕获双缓冲和上下界渲染单元。",
    "sim/tb_performance_held_write.sv": "验证曲谱按住状态写入优化与冻结参考的一致性。",
    "sim/tb_slider_expression_control.sv": "验证音量、弯音、颤音映射和反压期间参数稳定。",
    "sim/tb_slider_liveness.sv": "验证滑条活动和菜单操作不会导致功能接口永久等待。",
    "sim/tb_stable_chord_mix.sv": "验证固定单声部标度下新增音符不会因声部计数跨档而减半，并检查峰值限制。",
    "sim/tb_stereo_peak_limiter.sv": "验证立体声峰值保护的阈值、恢复和接口反压。",
    "sim/tb_sustain_allocator.sv": "联合原分配器验证4/64声部延音、同音重触发、满载和声部回收。",
    "sim/tb_sustain_gate.sv": "验证4/64声部延音门的ON/OFF、关延音扫描、快速切换、复位和反压。",
    "sim/tb_sustain_menu.sv": "验证延音菜单和OLED实际开关状态，含旧菜单兼容。",
    "sim/tb_sustain_neutral.sv": "延音关闭与原音源的逐样本PCM对照；测试包络/命令安排有特定条件，不能泛化为所有周期绝对相同。",
    "sim/tb_sustain_router.sv": "验证延音协议字段、ACK去重、状态快照、反压和非法命令拒绝。",
    "sim/tb_sustain_system.sv": "通过真实UART及64声部音源验证菜单/远程延音与Panic联合流程。",
}

PACKAGE_NAMES = {
    "package-chord-touch": "固定增益和弦与触摸提前上报",
    "package-headroom-smoothing": "旧分档增益平滑实验",
    "package-menu-hierarchy": "分层菜单与滑条表情",
    "package-oled-idle-wave": "OLED空闲波形",
    "package-slider-idle10": "滑条10秒空闲",
    "package-windows-minimized": "Windows最小化后台播放",
}
for stem, label in PACKAGE_NAMES.items():
    PURPOSES[f"scripts/{stem}.py"] = f"将{label}的源码、构建结果和证据整理为独立交付包；打包本身不证明实物通过。"


def file_link(path, label=None):
    """发布时使用独立分支源码链接，避免GitHub文档依赖本机C盘路径。"""
    target = "https://github.com/wujijun11/git/blob/codex/sustain-20261030/TangMega60K_Synth/" + quote(path, safe="/")
    return f"[{label or path}](<{target}>)"


def current_paths():
    """只读Git文件清单，包含未提交新文件；不切换分支、不联网。"""
    raw = subprocess.check_output(
        ["git", "ls-files", "--cached", "--others", "--exclude-standard", "-z"],
        cwd=ROOT,
    ).decode("utf-8")
    return sorted({
        path for path in raw.split("\0")
        if path and Path(path).suffix.lower() in CODE_EXTENSIONS
        and not path.startswith(EXCLUDED) and (ROOT / path).is_file()
    })


def parse_rtl():
    """复用既有解析器；不写字节码、不执行所检查的HDL。"""
    sys.dont_write_bytecode = True
    spec = importlib.util.spec_from_file_location(
        "source_catalog", ROOT / "scripts/catalog-submission-sources.py"
    )
    catalog = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(catalog)
    sources = {
        path.relative_to(ROOT).as_posix(): path.read_text(encoding="utf-8-sig")
        for path in (ROOT / "rtl").rglob("*") if path.suffix in {".v", ".sv"}
    }
    modules = catalog.modules_from_sources(sources)
    reachable = set()
    pending = ["board_contest_full_top"]
    while pending:
        name = pending.pop()
        if name not in reachable:
            reachable.add(name)
            pending.extend(item["module"] for item in modules[name]["instances"])
    return modules, reachable


def project_files():
    """解析工作区及冻结构建工程；二者GAO配置可能不同，分别保留。"""
    paths = []
    for item in ET.parse(ROOT / "full/ContestFull.gprj").getroot().findall("./FileList/File"):
        if item.get("enable") == "1" and item.get("type") == "file.verilog":
            paths.append((ROOT / "full" / item.get("path")).resolve().relative_to(ROOT).as_posix())
    return paths


def rtl_layer(path):
    """职责分层独立于物理文件夹；一个文件中可能定义多个紧密关联模块。"""
    if path in {
        "rtl/board/board_contest_full_top.v", "rtl/board/board_bringup_top.v",
        "rtl/board/audio_boot_status.v", "rtl/instrument_full_system.v",
    }:
        return "01 总装、启动与复位"
    if path.startswith("rtl/clock/"):
        return "02 时钟基础"
    if path.startswith("rtl/sensors/"):
        return "03 触摸采集与硬件驱动"
    if path in {
        "rtl/captain_control_top_v2.v", "rtl/voice_allocator_v2.v",
        "rtl/event_fifo_v2.v", "rtl/expression_controls_v2.v",
        "rtl/control/sustain_command_gate.v",
    }:
        return "06 V2队列、声部分配与延音"
    if path.startswith(("rtl/control/", "rtl/remote/")):
        return "04 通信、菜单与控制参数"
    if path.startswith("rtl/performance/") and not path.endswith("ws2812_guide.v"):
        return "05 曲谱、录制与学习"
    if path.startswith("rtl/audio/"):
        return "07 音频合成、混音与音效"
    if path == "rtl/i2s_tx.v":
        return "08 数字音频输出"
    if path.startswith("rtl/visual/") or path.endswith("ws2812_guide.v"):
        return "09 OLED、HDMI与灯板显示"
    return "10 独立入口或旧协议"


def code_layer(path):
    if path.startswith("rtl/"):
        return rtl_layer(path)
    if path.startswith("desktop/tests/"):
        return "Windows验证"
    if path.startswith("desktop/web/"):
        return "Windows界面与前端业务"
    if path.startswith("desktop/score_library/"):
        return "Windows曲库与MIDI数据处理"
    if path.startswith("desktop/realtime_native/"):
        return "Windows原生后台调度"
    if path.startswith("desktop/"):
        return "Windows宿主、通信与本地存储"
    if path.startswith("mobile/tests/"):
        return "手机验证"
    if path.startswith("mobile/web/"):
        return "手机界面、业务与MIDI处理"
    if path.startswith("mobile/"):
        return "Android原生驱动与构建"
    if path.startswith("firmware/ble_bridge/tests/"):
        return "C3固件验证"
    if path.startswith("firmware/ble_bridge/"):
        return "C3蓝牙与UART桥接"
    if path.startswith("firmware/libraries/"):
        return "第三方BLE库及其接口"
    if path.startswith("sim/"):
        return "HDL仿真、参考模型与波形脚本"
    if path.startswith("scripts/"):
        return "构建、验证、离线生成与打包工具"
    if path.startswith("hardware/"):
        return "硬件CAD、布局与制造资料辅助代码"
    return "独立小工程或接入示例"


def describe(path, old_purposes):
    """优先当前人工说明，再采用已有逐文件用途；不把未知项写成已验证。"""
    if path in PURPOSES:
        return PURPOSES[path]
    if path in old_purposes:
        return old_purposes[path]
    if path.startswith("firmware/libraries/"):
        return "BridgeBLE第三方库内部实现或头文件，供C3固件使用；不是FPGA合成音源。"
    raise ValueError(f"缺少明确用途，请补充：{path}")


def build_inventory():
    old = json.loads((ROOT / "docs/作品文档准备_20261026/文件用途.json").read_text(encoding="utf-8-sig"))
    modules, reachable = parse_rtl()
    listed = project_files()
    records = []
    for path in current_paths():
        names = sorted(name for name, item in modules.items() if item["file"] == path)
        raw = (ROOT / path).read_bytes()
        records.append({
            "path": path, "layer": code_layer(path), "purpose": describe(path, old),
            "modules": names, "listed_in_main_project": path in listed,
            "static_top_reachable": any(name in reachable for name in names),
            "bytes": len(raw), "sha256": hashlib.sha256(raw).hexdigest().upper(),
        })
    found = {record["path"] for record in records}
    if len(listed) != len(set(listed)) or set(listed) - found:
        raise ValueError("主工程HDL重复或缺失")
    if any(not (ROOT / path).is_file() for path in listed):
        raise ValueError("主工程HDL路径不存在")
    simple_modules = {
        name: {"file": item["file"], "instances": item["instances"],
               "static_top_reachable": name in reachable}
        for name, item in modules.items()
    }
    return records, simple_modules, listed, reachable


def write_rtl_guide(records, modules, listed, reachable):
    rows = [record for record in records if record["listed_in_main_project"]]
    lines = [
        "# FPGA逐文件与逐模块分层", "",
        "[先看总览](README.md) · [全部软件与工具文件](全部源码文件分类.md)", "",
        f"当前full工程列出{len(listed)}个HDL文件，定义{len(modules)}个模块；"
        f"从board_contest_full_top静态遍历可达{len(reachable)}个模块、"
        f"{sum(row['static_top_reachable'] for row in rows)}个文件。", "",
        "这里的“静态可达”包含条件分支，并不表示每条分支最终都会占用硬件。"
        "模块数量也不等于振荡器数量。厂商PLLA、输出串行器等原语另由综合工具处理。", "",
        "## 当前配置特别需要分清的分支", "",
        "| 文件/开关 | 当前含义 |", "|---|---|",
        "| STABLE_CHORD_MIX_ENABLE=1 | 使用固定单声部标度和实际峰值保护，不按声部数跨档减半。 |",
        "| headroom_smoother.v | 旧平滑方案留在源码；固定增益分支优先，因此没有接入当前音频计算。 |",
        "| FX_ENABLE=0 / audio_fx.v | 音源内部固定延迟旁路；当前效果使用外层runtime_audio_fx。 |",
        "| MENU_HIERARCHY_ENABLE=1 | 使用menu_hierarchy和slider_expression_control；旧平面菜单与独立音量映射仅供兼容。 |",
        "| SUSTAIN_ENABLE=1 | 有延音控制能力，运行时开关默认关闭。 |",
        "| FM_ENABLE=1 | FM音色仍可切换，主钢琴音色继续采用原八成分polar_lane。 |",
        "| OLED/HDMI/WS2812 | 都读取状态或样本，不承担主音源运算。显示不应反压实时音源。 |", "",
        "## 当前顶层关系中的文件", "",
    ]
    for layer in sorted({row["layer"] for row in rows if row["static_top_reachable"]}):
        selected = [row for row in rows if row["static_top_reachable"] and row["layer"] == layer]
        lines.extend([f"### {layer}（{len(selected)}个文件）", "",
                      "| 文件 | 文件中定义的模块 | 职责 |", "|---|---|---|"])
        for row in sorted(selected, key=lambda item: item["path"]):
            names = "、".join(f"`{name}`" for name in row["modules"])
            lines.append(f"| {file_link(row['path'])} | {names} | {row['purpose']} |")
        lines.append("")
    inactive = sorted((row for row in rows if not row["static_top_reachable"]), key=lambda item: item["path"])
    lines.extend([f"## 工程列出、但当前完整顶层未实例化的文件（{len(inactive)}个）", "",
                  "这些文件用于旧接口、学习示例和专项板级测试。它们不是额外同时运行的音源；"
                  "不要删除后再猜工程能否编译，也不要拿独立测试入口替换完整顶层。", "",
                  "| 文件 | 模块 | 用途 |", "|---|---|---|"])
    for row in inactive:
        names = "、".join(f"`{name}`" for name in row["modules"])
        lines.append(f"| {file_link(row['path'])} | {names} | {row['purpose']} |")
    lines.extend(["", "## 一个文件定义多个模块时怎么看", "",
                  "| 文件 | 包含的模块 |", "|---|---|"])
    for row in rows:
        if len(row["modules"]) > 1:
            lines.append(f"| {file_link(row['path'])} | {'、'.join(row['modules'])} |")
    lines.extend(["", "完整直接实例关系保存在本目录的模块清单.json中。"
                  "阅读时先从父模块找到实例名，再看对应module定义；模块名与实例名不是同一个概念。", ""])
    (OUTPUT / "FPGA模块逐文件说明.md").write_text("\n".join(lines), encoding="utf-8")


def write_all_code(records):
    lines = [
        "# 全部源码文件分类", "", "[返回总览](README.md)", "",
        f"共{len(records)}个代码/脚本文件。列入此表仅表示已清点用途，不表示本轮运行过每个测试。", "",
        "范围：当前Git跟踪文件与未忽略的新代码；包括自研代码、C3第三方BLE库、"
        "硬件CAD辅助脚本、独立小工程和测试。排除docs历史报告中的代码副本、verification运行副本、"
        "releases/delivery分发副本、tmp依赖和assets素材。ROM、约束、项目配置另在总览说明，"
        "不把它们当作可执行源码重复统计。", "",
    ]
    for layer in sorted({row["layer"] for row in records}):
        selected = [row for row in records if row["layer"] == layer]
        lines.extend([f"## {layer}（{len(selected)}个）", "",
                      "| 文件 | 用途 |", "|---|---|"])
        for row in sorted(selected, key=lambda item: item["path"]):
            lines.append(f"| {file_link(row['path'])} | {row['purpose']} |")
        lines.append("")
    (OUTPUT / "全部源码文件分类.md").write_text("\n".join(lines), encoding="utf-8")


def write_overview(records, listed, reachable):
    counts = collections.Counter(row["path"].split("/")[0] for row in records)
    text = """# 弦光工程模块分层与Flash更新说明

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
"""
    text += "\n本次清点数量：" + "，".join(f"{key} {value}个" for key, value in sorted(counts.items())) + "。\n"
    (OUTPUT / "README.md").write_text(text, encoding="utf-8")


def main():
    records, modules, listed, reachable = build_inventory()
    OUTPUT.mkdir(parents=True, exist_ok=True)
    write_overview(records, listed, reachable)
    write_rtl_guide(records, modules, listed, reachable)
    write_all_code(records)
    metadata = {
        "date": "2026-10-30", "scope": "current local sustain worktree; not HEAD-only",
        "branch": subprocess.check_output(["git", "branch", "--show-current"], cwd=ROOT).decode().strip(),
        "base_commit": subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=ROOT).decode().strip(),
        "warning": "static graph includes all generate branches; not a synthesis utilization or test pass claim",
        "code_file_count": len(records), "main_hdl_file_count": len(listed),
        "rtl_module_count": len(modules), "static_reachable_module_count": len(reachable),
        "records": records, "modules": modules,
    }
    (OUTPUT / "模块清单.json").write_text(json.dumps(metadata, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    report = {
        "all_main_hdl_paths_exist": True,
        "all_main_hdl_files_classified": len(listed),
        "all_code_files_have_purpose": len(records),
        "duplicate_main_hdl_paths": 0,
        "static_top_reachable_files": sum(row["static_top_reachable"] for row in records),
        "not_instantiated_from_current_top_files": sum(row["listed_in_main_project"] and not row["static_top_reachable"] for row in records),
        "eda_rerun": False, "hardware_accessed": False, "git_push": False,
    }
    (OUTPUT / "清点验证.json").write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    print(json.dumps(report, ensure_ascii=False))


if __name__ == "__main__":
    main()
