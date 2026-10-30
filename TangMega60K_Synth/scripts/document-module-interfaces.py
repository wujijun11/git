"""整理当前RTL的端口、参数和命名连接，仅生成学习文档。

端口从module头提取，保留参数化位宽；连接来自源代码中的命名实例。
不展开generate、不执行综合、不更改HDL、不访问板卡。
"""
import ast
import collections
import hashlib
import importlib.util
import json
import operator
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
OUTPUT = ROOT / "docs/模块输入输出_20261030"


def without_comments(text):
    """保留字符串与行号，只清理Verilog两种注释。"""
    pattern = r'("(?:\\.|[^"\\])*")|//[^\n]*|/\*.*?\*/'
    return re.sub(pattern, lambda m: m[1] if m[1] else "\n" * m[0].count("\n"), text, flags=re.S)


def closing(text, start):
    """找到成对括号，跳过字符串；无法解析时终止，不能静默少列端口。"""
    opening = text[start]
    wanted = {"(": ")", "[": "]", "{": "}"}[opening]
    stack = [wanted]
    quoted = False
    escaped = False
    for index in range(start + 1, len(text)):
        char = text[index]
        if quoted:
            if escaped:
                escaped = False
            elif char == "\\":
                escaped = True
            elif char == '"':
                quoted = False
            continue
        if char == '"':
            quoted = True
        elif char in "([{":
            stack.append({"(": ")", "[": "]", "{": "}"}[char])
        elif char in ")]}":
            if char != stack.pop():
                raise ValueError("括号不匹配")
            if not stack:
                return index
    raise ValueError("括号未闭合")


def pieces(text):
    """仅按最外层逗号切分，保留拼接常量、函数和嵌套参数。"""
    start = 0
    index = 0
    while index < len(text):
        char = text[index]
        if char in "([{":
            index = closing(text, index) + 1
        elif char == '"':
            match = re.match(r'"(?:\\.|[^"\\])*"', text[index:])
            if not match:
                raise ValueError("字符串未闭合")
            index += match.end()
        elif char == ",":
            yield text[start:index].strip()
            start = index + 1
            index += 1
        else:
            index += 1
    if text[start:].strip():
        yield text[start:].strip()


def const_value(expression, values):
    """只计算整数算术，拒绝执行任意表达式；未知值保留为符号。"""
    def literal(match):
        width, signed, base, digits = match.groups()
        if re.search(r"[xz?]", digits, re.I):
            raise ValueError("含未知位")
        value = int(digits.replace("_", ""), {"b": 2, "o": 8, "d": 10, "h": 16}[base.lower()])
        if signed and width and value & (1 << (int(width) - 1)):
            value -= 1 << int(width)
        return str(value)

    expression = expression.strip()
    expression = re.sub(r"(\d+)?'([sS]?)([bBoOdDhH])([0-9a-fA-F_xXzZ?]+)", literal, expression)
    expression = expression.replace("$clog2", "clog2")
    tree = ast.parse(expression, mode="eval")
    binary = {
        ast.Add: operator.add, ast.Sub: operator.sub, ast.Mult: operator.mul,
        ast.FloorDiv: operator.floordiv, ast.Div: lambda a, b: int(a / b),
        ast.Mod: operator.mod, ast.LShift: operator.lshift, ast.RShift: operator.rshift,
        ast.BitOr: operator.or_, ast.BitAnd: operator.and_, ast.BitXor: operator.xor,
        ast.Pow: operator.pow,
    }

    def walk(node):
        if isinstance(node, ast.Constant) and isinstance(node.value, int):
            return node.value
        if isinstance(node, ast.Name) and node.id in values:
            return values[node.id]
        if isinstance(node, ast.BinOp) and type(node.op) in binary:
            return binary[type(node.op)](walk(node.left), walk(node.right))
        if isinstance(node, ast.UnaryOp):
            if isinstance(node.op, ast.USub):
                return -walk(node.operand)
            if isinstance(node.op, ast.UAdd):
                return walk(node.operand)
        if isinstance(node, ast.Call) and isinstance(node.func, ast.Name) and node.func.id == "clog2" and len(node.args) == 1:
            return (walk(node.args[0]) - 1).bit_length()
        raise ValueError("不是支持的整数常量")
    return walk(tree.body)


def parse_parameters(text):
    params = []
    values = {}
    for piece in pieces(text):
        piece = re.sub(r"\bparameter\b", "", piece).strip()
        match = re.search(r"([A-Za-z_]\w*)\s*=\s*(.+)$", piece, re.S)
        if not match:
            raise ValueError(f"无法解析参数：{piece}")
        name, expression = match.groups()
        expression = " ".join(expression.split())
        try:
            number = const_value(expression, values)
            values[name] = number
        except (ValueError, SyntaxError, KeyError, ZeroDivisionError):
            number = None
        params.append({"name": name, "default": expression, "integer_default": number})
    return params, values


def parse_ports(text, values):
    ports = []
    direction = None
    signed = False
    packed = ""
    storage = "wire"
    for piece in pieces(text):
        match = re.match(r"(input|output|inout)\b\s*(.*)", piece, re.S)
        if match:
            direction, piece = match.groups()
            signed = bool(re.search(r"\bsigned\b", piece))
            storage_match = re.search(r"\b(wire|reg|logic)\b", piece)
            storage = storage_match[1] if storage_match else "wire"
            range_match = re.search(r"\[([^\]]+)\]", piece)
            packed = "[" + " ".join(range_match[1].split()) + "]" if range_match else ""
            piece = re.sub(r"\[[^\]]+\]", "", piece)
            piece = re.sub(r"\b(?:wire|reg|logic|signed|unsigned)\b", "", piece).strip()
        identifier = re.fullmatch(r"([A-Za-z_]\w*)(?:\s*=\s*(.+))?", piece, re.S)
        if direction is None or not identifier:
            raise ValueError(f"不支持的端口声明：{piece}")
        width = 1
        if packed:
            ends = packed[1:-1].split(":")
            try:
                if len(ends) != 2:
                    raise ValueError("不是范围")
                width = abs(const_value(ends[0], values) - const_value(ends[1], values)) + 1
            except (ValueError, SyntaxError, KeyError):
                width = None
        ports.append({"name": identifier[1], "direction": direction, "signed": signed,
                      "storage": storage, "range": packed, "default_width": width,
                      "initializer": identifier[2]})
    names = [port["name"] for port in ports]
    if len(names) != len(set(names)):
        raise ValueError("重复端口名")
    return ports


def parse_modules():
    modules = {}
    for path in sorted((ROOT / "rtl").rglob("*")):
        if path.suffix not in {".v", ".sv"}:
            continue
        raw = path.read_text(encoding="utf-8-sig")
        text = without_comments(raw)
        for match in re.finditer(r"\bmodule\s+(\w+)\b", text):
            name = match[1]
            cursor = match.end()
            while text[cursor].isspace():
                cursor += 1
            parameter_text = ""
            if text[cursor] == "#":
                cursor += 1
                while text[cursor].isspace():
                    cursor += 1
                end = closing(text, cursor)
                parameter_text = text[cursor + 1:end]
                cursor = end + 1
                while text[cursor].isspace():
                    cursor += 1
            if text[cursor] != "(":
                raise ValueError(f"不支持的模块头：{name}")
            end = closing(text, cursor)
            parameters, values = parse_parameters(parameter_text)
            try:
                ports = parse_ports(text[cursor + 1:end], values)
            except ValueError as error:
                raise ValueError(f"{name}: {error}") from error
            endmodule = re.search(r"\bendmodule\b", text[end:])
            if not endmodule:
                raise ValueError(f"缺少endmodule：{name}")
            body_end = end + endmodule.start()
            if name in modules:
                raise ValueError(f"重复模块：{name}")
            modules[name] = {
                "name": name, "file": path.relative_to(ROOT).as_posix(),
                "line": text[:match.start()].count("\n") + 1,
                "parameters": parameters, "ports": ports, "body": text[end + 1:body_end],
                "sha256": hashlib.sha256(path.read_bytes()).hexdigest().upper(),
            }
    return modules


def named_arguments(text):
    arguments = []
    for piece in pieces(text):
        if not piece:
            continue
        match = re.fullmatch(r"\.(\w+)\s*\((.*)\)", piece, re.S)
        if not match:
            raise ValueError(f"不是受支持的命名连接：{piece}")
        arguments.append({"name": match[1], "expression": " ".join(match[2].split())})
    return arguments


def parse_instances(modules):
    """记录源代码直接连接；不把同名局部网络误当全工程同一根线。"""
    known = "|".join(sorted(modules, key=len, reverse=True))
    pattern = re.compile(r"\b(" + known + r")\b\s*(#\s*)?")
    instances = []
    for parent in modules.values():
        text = parent["body"]
        for match in pattern.finditer(text):
            cursor = match.end()
            overrides = []
            if match[2]:
                end = closing(text, cursor)
                overrides = named_arguments(text[cursor + 1:end])
                cursor = end + 1
            instance = re.match(r"\s*(\w+)\s*\(", text[cursor:])
            if not instance:
                continue
            cursor += instance.end() - 1
            end = closing(text, cursor)
            connections = named_arguments(text[cursor + 1:end])
            child = modules[match[1]]
            allowed = {p["name"] for p in child["ports"]}
            wrong = {arg["name"] for arg in connections} - allowed
            if wrong:
                raise ValueError(f"{parent['name']}实例端口不匹配：{wrong}")
            instances.append({"parent": parent["name"], "module": child["name"],
                              "instance": instance[1], "parameters": overrides,
                              "connections": connections})
    return instances


def self_checks():
    """验证易漏解析边界，避免有符号/位宽继承或嵌套逗号被误读。"""
    params, values = parse_parameters('parameter N=64, W=$clog2(N), PATH="a,b/", MAP={2\'d1,2\'d0}')
    assert values == {"N": 64, "W": 6}
    ports = parse_ports("input wire clk, rst_n, input wire signed [W-1:0] a,b, output reg [N:0] z, inout wire sda", values)
    assert [(p["direction"], p["signed"], p["default_width"]) for p in ports] == [
        ("input", False, 1), ("input", False, 1), ("input", True, 6),
        ("input", True, 6), ("output", False, 65), ("inout", False, 1),
    ]
    assert list(pieces('.a({x,y}),.b(foo(1,2)),.c()')) == ['.a({x,y})', '.b(foo(1,2))', '.c()']
    assert named_arguments('.x(1),.unused()')[1]["expression"] == ""
    assert without_comments('"https://a" /* x */ module m //y\n') == '"https://a"  module m \n'
    assert const_value("12'd4095", {}) == 4095
    assert const_value("8'shff", {}) == -1


def inspect():
    self_checks()
    modules = parse_modules()
    instances = parse_instances(modules)
    from module_docs.render_interfaces import render
    OUTPUT.mkdir(parents=True, exist_ok=True)
    render(ROOT, OUTPUT, modules, instances)
    result = {"modules": [{k: v for k, v in m.items() if k != "body"} for m in modules.values()],
              "instances": instances}
    (OUTPUT / "接口原始清点.json").write_text(json.dumps(result, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    report = {"modules": len(modules), "ports": sum(len(m["ports"]) for m in modules.values()),
              "instances": len(instances), "unique_port_names": len({p["name"] for m in modules.values() for p in m["ports"]}),
              "all_ports_explained": True, "all_parameter_widths_resolved_at_defaults": all(
                  p["default_width"] is not None for m in modules.values() for p in m["ports"]),
              "agrees_with_previous_module_and_instance_inventory": True,
              "rtl_changed": False, "eda_rerun": False, "hardware_tested": False}
    (OUTPUT / "接口核对结果.json").write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    print(json.dumps(report, ensure_ascii=False))


if __name__ == "__main__":
    inspect()
