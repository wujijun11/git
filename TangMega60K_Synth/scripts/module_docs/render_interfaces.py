"""将已核对的接口信息输出为分层Markdown和机器清单。"""
import collections
import json
import re
from urllib.parse import quote

from .interface_guides import parameter_description, timing_description
from .interface_meanings import describe

SOURCE_URL = "https://github.com/wujijun11/git/blob/codex/sustain-20261030/TangMega60K_Synth/"
LAYER_FILES = {
    "01 总装、启动与复位": "01-总装启动.md",
    "02 时钟基础": "02-时钟.md",
    "03 触摸采集与硬件驱动": "03-触摸驱动.md",
    "04 通信、菜单与控制参数": "04-通信菜单表情.md",
    "05 曲谱、录制与学习": "05-曲谱录制学习.md",
    "06 V2队列、声部分配与延音": "06-V2声部分配延音.md",
    "07 音频合成、混音与音效": "07-音频引擎.md",
    "08 数字音频输出": "08-I2S输出.md",
    "09 OLED、HDMI与灯板显示": "09-显示与灯板.md",
    "10 备用入口、旧版与独立自检": "10-备用旧版入口.md",
}
DIRECTION = {"input": "输入", "output": "输出", "inout": "双向"}


def source_link(module):
    target = SOURCE_URL + quote(module["file"], safe="/") + f"#L{module['line']}"
    return f"[{module['file']}:{module['line']}]({target})"


def inline(text):
    return "`" + text.replace("|", "&#124;").replace("\n", " ") + "`"


def width_text(port):
    if not port["range"]:
        return "1位"
    return inline(port["range"]) + f"；默认{port['default_width']}位"


def incoming_instances(name, instances, reachable):
    matches = [item for item in instances if item["module"] == name]
    return sorted(matches, key=lambda item: (
        item["parent"] not in reachable,
        item["parent"] != "instrument_full_system",
        item["parent"], item["instance"],
    ))


def connection_example(name, port, instances, reachable):
    for item in incoming_instances(name, instances, reachable):
        for arg in item["connections"]:
            if arg["name"] == port["name"]:
                value = arg["expression"] or "未连接()"
                if len(value) > 65:
                    value = value[:62] + "…"
                return inline(item["parent"] + "." + item["instance"]) + "：" + inline(value)
    return "本清单无父实例命名接线；见独立工程或外部顶层。"


def module_section(module, instances, reachable):
    name = module["name"]
    lines = [f"## {name}", "", "定义：" + source_link(module), "",
             "用途：" + module["purpose"], "", "时序/注意事项：" + timing_description(module), ""]
    triggers = sorted(set(re.findall(r"always\s*@\s*\(([^)]*(?:posedge|negedge)[^)]*)\)", module["body"])))
    if triggers:
        lines.extend(["源码中本模块自己的边沿触发条件：" + "；".join(inline(" ".join(t.split())) for t in triggers) + "。子模块还可有自己的时序。", ""])
    else:
        lines.extend(["本模块未解析到自己的posedge/negedge always块；可能是组合计算或连接子模块的包装，不能仅因没有此类块就断言所有内部功能均为组合。", ""])
    if module["parameters"]:
        lines.extend(["### 编译参数（模块默认值）", "", "下列默认值不是当前父实例一定采用的值；覆盖项见本节末尾。", "",
                      "| 参数 | 默认表达式 | 含义/单位 |", "|---|---|---|"])
        for parameter in module["parameters"]:
            lines.append(f"| {inline(parameter['name'])} | {inline(parameter['default'])} | {parameter_description(parameter['name'])} |")
        lines.append("")
    for direction in ("input", "output", "inout"):
        ports = [port for port in module["ports"] if port["direction"] == direction]
        if not ports:
            continue
        lines.extend([f"### {DIRECTION[direction]}（{len(ports)}个）", "",
                      "| 端口 | 位宽 | 数值类型 | 作用、单位及条件 | 一处实际连接例 |",
                      "|---|---|---|---|---|"])
        for port in ports:
            kind = "有符号补码" if port["signed"] else "无符号/位图"
            if port["initializer"] is not None:
                kind += "；声明初值=" + inline(port["initializer"])
            lines.append(f"| {inline(port['name'])} | {width_text(port)} | {kind} | {describe(module, port)} | {connection_example(name, port, instances, reachable)} |")
        lines.append("")
    parents = incoming_instances(name, instances, reachable)
    if parents:
        lines.extend(["### 父级实例及参数覆盖", "",
                      "表中包含旧入口和条件分支，列出连接不表示分支最终启用。参数未覆盖时仍使用模块默认值。", "",
                      "| 父模块.实例 | 显式覆盖参数 | 父模块是否在完整顶层静态关系中 |", "|---|---|---|"])
        for item in parents:
            settings = "；".join(inline(arg["name"] + "=" + arg["expression"]) for arg in item["parameters"]) or "未显式覆盖"
            lines.append(f"| {inline(item['parent'] + '.' + item['instance'])} | {settings} | {'是（含条件分支）' if item['parent'] in reachable else '否/备用入口'} |")
        lines.append("")
    lines.extend(["[回到总索引](README.md)", ""])
    return lines


def write_layers(output, modules, instances, reachable):
    for layer, filename in LAYER_FILES.items():
        chosen = [m for m in modules.values() if m["layer"] == layer]
        if not chosen:
            continue
        lines = ["# " + layer, "", "[总索引](README.md) · [先理解接口规则](接口阅读方法.md) · [全部命名连接](实例连接索引.md)", "",
                 "端口方向始终相对本模块。位宽中的“默认”按模块声明计算，父实例覆盖值另列；连接例为父模块局部网络名，不是板上引脚名。", ""]
        for module in sorted(chosen, key=lambda m: m["name"]):
            lines.extend(module_section(module, instances, reachable))
        (output / filename).write_text("\n".join(lines), encoding="utf-8")


def write_bindings(output, modules, instances, reachable):
    lines = ["# 全部RTL命名实例连接索引", "", "[总索引](README.md)", "",
             "按父模块分组；每一行都是源码中的.port(网络/表达式)。同名网络只有在同一父模块内才可能是同一根线。"
             "generate复制数量和条件不在此展开，SIM与综合互斥分支也可能同时出现。未连接()和常量连接如实保留。", ""]
    for parent in sorted({item["parent"] for item in instances}):
        lines.extend(["## " + parent, "", "定义：" + source_link(modules[parent]), ""])
        for item in sorted((i for i in instances if i["parent"] == parent), key=lambda i: i["instance"]):
            lines.extend([f"### {item['instance']}：{item['module']}", "",
                          "| 子模块端口 | 相对子模块方向 | 父级实际网络/表达式 |", "|---|---|---|"])
            by_name = {port["name"]: port for port in modules[item["module"]]["ports"]}
            for arg in item["connections"]:
                lines.append(f"| {inline(arg['name'])} | {DIRECTION[by_name[arg['name']]['direction']]} | {inline(arg['expression']) if arg['expression'] else '显式未连接()'} |")
            omitted = set(by_name) - {arg["name"] for arg in item["connections"]}
            if omitted:
                lines.extend(["", "该实例未写出的端口：" + "、".join(inline(name) for name in sorted(omitted)) + "。是否可省略须以该调用用途为准。"])
            lines.append("")
    (output / "实例连接索引.md").write_text("\n".join(lines), encoding="utf-8")


def write_index(output, modules, instances, reachable):
    total_ports = sum(len(module["ports"]) for module in modules.values())
    lines = ["# 当前工程各模块输入输出索引", "",
             "日期：2026-10-30。版本：codex/sustain-20261030，基于Chord F571，延音测试位流UserCode 7D2F。", "",
             "**独立测试版，新增延音尚未上板验收。** 端口清点不等于实际硬件功能全部通过。", "",
             f"覆盖90个主工程HDL文件中的{len(modules)}个模块、{total_ports}个端口，另列{len(instances)}处已知模块命名实例。"
             "包括旧入口和条件分支；不包含厂商原语内部端口、测试台层次或软件每个函数。", "",
             "先读[接口阅读方法](接口阅读方法.md)，再按下表看模块。想追一根线，查看[实例连接索引](实例连接索引.md)。", "",
             "| 层次 | 模块数 | 端口数 | 文档 |", "|---|---|---|---|"]
    for layer, filename in LAYER_FILES.items():
        chosen = [m for m in modules.values() if m["layer"] == layer]
        if chosen:
            lines.append(f"| {layer} | {len(chosen)} | {sum(len(m['ports']) for m in chosen)} | [逐模块输入输出]({filename}) |")
    lines.extend(["", "## 快速查找模块", "", "| 模块 | 所属层 | 输入/输出/双向数量 |", "|---|---|---|"])
    for module in sorted(modules.values(), key=lambda m: m["name"]):
        count = collections.Counter(p["direction"] for p in module["ports"])
        target = LAYER_FILES[module["layer"]] + "#" + module["name"].lower()
        lines.append(f"| [{module['name']}]({target}) | {module['layer']} | {count['input']} / {count['output']} / {count['inout']} |")
    lines.extend(["", "## 当前配置特别说明", "",
                  "- voice_state_ram默认WIDTH=101，当前voice_engine.u_state覆盖为125，不能按默认101位连当前音源。",
                  "- inout SCL/SDA是开漏双向总线，不能把它当成普通永远推挽的output。",
                  "- 旧headroom_smoother仍在源码中，当前固定增益分支不启用它。",
                  "- 当前新延音默认关闭；有延音接口不代表上电就一直延音。",
                  "- 上位机通信帧V1和内部音符控制V2是两套不同编号，不表示彼此不兼容。",
                  "- 源码链接指向本独立分支；重新修改接口后应重新生成，不要继续引用旧表。", "",
                  "[机器可读接口清单](接口原始清点.json) · [静态检查结果](接口核对结果.json) · [本次技术说明](本次接口整理实现说明.md)", ""])
    (output / "README.md").write_text("\n".join(lines), encoding="utf-8")


def write_reading_guide(output):
    text = """# 把输入输出看成模块之间的交接

[回到总索引](README.md)

## 输入、输出相对谁

模块好比一个小工作台。input是别人送进来的信息，output是本工作台送出去的信息。
同一根线从发送者看是output，从接收者看就是input。大部分线在FPGA内部，不需要你拿杜邦线逐个连接。
真正接到板外的信号由board_contest_full_top端口和CST引脚约束决定。

以新延音门为例：

```text
分配器cmd_valid输出 → 延音门in_valid输入
分配器cmd_ready输入 ← 延音门in_ready输出
延音门out_valid输出 → 音源cmd_valid输入
延音门out_ready输入 ← 音源cmd_ready输出
```

ready逆着数据方向返回，因为它表达“我现在能接”。输入输出不是按信号名字valid/ready固定判断，
而是按这个信号对当前模块的方向判断。

## 位宽与signed怎么看

```verilog
input wire [6:0] cmd_note;
input wire signed [12:0] active_bend_cents;
output wire signed [23:0] sample_left;
```

- cmd_note是7位无符号音高编号，可编码0..127。例如69通常代表A4，不能直接把440写进去。
- active_bend_cents是13位有符号数，传负数可以降音，单位音分；100音分是一个半音。
- sample_left是24位有符号振幅，范围−8388608..8388607，是某一瞬间的振幅，不是音高编号。

位宽能编码的范围，不等于业务允许的范围。例如12位滑条位置能编码0..4095，但当前有效标度是0..3072。
位图和普通整数也不同：25位touch_mask每一位对应一个键，并不是一个0..33554431的演奏参数。

wire/reg是Verilog声明类型；reg并不保证一定综合成寄存器。ADSR的output reg由组合always计算，
实际是否保存状态要看触发条件和赋值完整性。

## valid/ready如何交接

对于文档明确标为标准流握手的通路，在其所属时钟上升沿满足：

```text
valid=1 且 ready=1 → 完成一次传输
valid=1 且 ready=0 → 发送者继续保持valid及整组负载
valid=0           → 本拍没有有效传输
```

例如音源sample_valid=1而音效sample_ready=0时，左右样本必须一起保持，不能只保持左路，
也不能提前更新为下一帧。ready=1只是“可接收”，并不要求发送者必须先等ready才能把valid拉高。
复位/取消是否可撤回必须服从具体模块协议，不能自行把“松手了”作为撤回已呈现事件的理由。

注意：并非每个名为valid的信号都能等待ready。remote_uart_rx.valid只有接收字节脉冲，
没有ready；观察sample_valid也不允许显示反压音频。polar_lane.valid表示一次流水线结果，
没有out_ready。每个模块说明都区分这些情况。

## 为什么音源有三套接口

| 接口组 | 方向（相对voice_engine） | 交接内容 |
|---|---|---|
| cmd_* | 输入命令、输出cmd_ready | 某个声部按下/松开，音高、力度、音色 |
| done_* | 输出完成、输入done_ready | 某个声部的释放包络已经结束，可以回收槽位 |
| sample_* | 输出左右样本、输入sample_ready | 所有声部混合后的一对24位PCM |

因此cmd_voice=17不代表只有17个音，也不代表I2S有64个声道。
一个48kHz采样帧最终是一对左/右混音样本；64个逻辑声部在音源里算好再混合。

延音只改变OFF何时送给音源。它不把done伪造成提前完成，也不改变sample接口。
关闭延音后，已松键的声音进入释放；仍按住的声部继续发声。

## 帧边界为什么有engine_sample_begin

表情提交器把新增益/弯音/颤音先暂存，等begin上升沿再提交为active_*。
由于时序寄存器同一边沿更新，音源在下一上升沿或之后读取新值。
同一帧64个声部用同一份参数，避免前半帧用旧音量、后半帧用新音量。
pitch_expression的全局LFO也每生成帧只推进一次，而不是每个声部推进一次。

## 编译参数和实际连接

parameter决定综合出的电路或ROM路径，input是电路运行时送入的信息。
接口表的“默认101位”来自voice_state_ram的WIDTH默认值，而当前实例明确写WIDTH=125，
所以当前RAM数据口实际按125位连接。

连接索引里的“父模块.实例”是某个具体工作台，例如voice_engine.u_state。
同名module可以实例化多次，例如polar_lane有两条lane。实例数量、逻辑声部数、泛音分量数要分开理解。
本索引包含generate条件两侧源码，但不会证明两侧都综合进入了最终位流。

## 时钟与复位先看清

当前主要时钟是板载参考50MHz、音频工作49.152MHz、视频像素25MHz/串行125MHz。
48kHz是实际音频采样率；I2S的3.072MHz BCLK是串行输出时序，不能与工作时钟混淆。
rst_n/resetn通常低有效，reset高有效；同步/异步方式以每模块的always边沿和子模块连接为准。
DDS/ADSR组合模块没有clk，不能凭名字给它们补一个时钟。

SCL/SDA为开漏，总线高电平由上拉产生。该文档仅整理已确认接口，不新增引脚或电压接法。
"""
    (output / "接口阅读方法.md").write_text(text, encoding="utf-8")


def render(root, output, modules, instances):
    baseline = json.loads((root / "docs/模块分层_20261030/模块清单.json").read_text(encoding="utf-8"))
    records = {record["path"]: record for record in baseline["records"]}
    expected = baseline["modules"]
    if set(modules) != set(expected):
        raise ValueError("接口清点与前一份模块清单不一致")
    reachable = {name for name, value in expected.items() if value["static_top_reachable"]}
    expected_edges = collections.Counter(
        (parent, edge["module"], edge["instance"])
        for parent, item in expected.items() for edge in item["instances"]
    )
    actual_edges = collections.Counter((i["parent"], i["module"], i["instance"]) for i in instances)
    if expected_edges != actual_edges:
        raise ValueError("两个解析器的实例统计不一致")
    for module in modules.values():
        record = records[module["file"]]
        if module["sha256"] != record["sha256"]:
            raise ValueError("源文件已变化，须重新核对分层清单：" + module["file"])
        module["purpose"] = record["purpose"]
        module["layer"] = record["layer"] if module["name"] in reachable else "10 备用入口、旧版与独立自检"
        for port in module["ports"]:
            port["meaning"] = describe(module, port)
        for parameter in module["parameters"]:
            parameter["meaning"] = parameter_description(parameter["name"])
        module["timing_note"] = timing_description(module)
    write_reading_guide(output)
    write_layers(output, modules, instances, reachable)
    write_bindings(output, modules, instances, reachable)
    write_index(output, modules, instances, reachable)
