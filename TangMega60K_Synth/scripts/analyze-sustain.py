"""独立核对实际OLED像素、默认关闭时PCM等价；生成真实仿真帧预览。"""
import argparse
import csv
import importlib.util
import json
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def analyze_pixels(captures, output):
    manifest = json.loads((ROOT / "licenses/menu-hierarchy-font/manifest.json").read_text(encoding="utf-8"))
    glyphs = manifest["glyphs"]
    font = [int(row, 16) for row in (ROOT / "rtl/audio/rom/menu_hierarchy_font.hex").read_text().splitlines()]
    frames = {}
    with (captures / "sustain_menu_pixels.csv").open(newline="") as source:
        for raw in csv.DictReader(source):
            row = {key: int(value) for key, value in raw.items()}
            page, column = row["page"], row["column"]
            lines = ["声音设置", "音色音区音效延音", "事件数 0000", "长按右端回音量"]
            if row["view"] == 9:
                lines = ["延音设置", "关闭开启返回主页", "延音开启" if row["sustain"] else "延音关闭", "长按右端回音量"]
            text = lines[page // 2].ljust(8)
            expected = font[glyphs[text[column // 16]] * 32 + (page % 2) * 16 + column % 16]
            if page // 2 == 1 and column // 32 == row["zone"]:
                expected ^= 255
            if row["data"] != expected:
                raise ValueError(f"延音OLED像素不同：{row}")
            pixels = frames.setdefault(row["frame"], {})
            address = page * 128 + column
            if address in pixels:
                raise ValueError("OLED像素重复")
            pixels[address] = expected
    if set(frames) != {0, 1, 2} or any(set(data) != set(range(1024)) for data in frames.values()):
        raise ValueError("OLED整屏不完整")
    spec = importlib.util.spec_from_file_location("oled_pixels", ROOT / "scripts/analyze-oled-wave.py")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    names = ("声音菜单_延音入口", "延音设置_关闭", "延音设置_开启")
    for index, name in enumerate(names):
        module.render([frames[index][address] for address in range(1024)], output / f"{name}.png")
    return {"frames": 3, "bytesCompared": 3072, "source": "actual RTL simulation pixels", "passed": True}


def analyze_neutral(captures):
    result = {}
    for name in ("sustain_neutral_piano.csv", "sustain_neutral_sine.csv"):
        with (captures / name).open(newline="") as source:
            rows = list(csv.DictReader(source))
        if len(rows) < 3000:
            raise ValueError("中性参数PCM样本不足")
        for row in rows:
            if row["old_left"] != row["new_left"] or row["old_right"] != row["new_right"]:
                raise ValueError("延音关闭的帧内相同事件PCM不一致")
        result[name] = {"frames": len(rows), "bitExact": True}
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("captures", type=Path)
    parser.add_argument("output", type=Path)
    args = parser.parse_args()
    args.output.mkdir(parents=True, exist_ok=True)
    result = {"pixels": analyze_pixels(args.captures, args.output),
              "neutral": analyze_neutral(args.captures), "hardwareTested": False}
    (args.output / "analysis.json").write_text(json.dumps(result, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    print(json.dumps(result, ensure_ascii=False))


if __name__ == "__main__":
    main()
