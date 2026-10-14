"""Print a constant pixel-to-key map; never guess the purchased panel's wiring."""
import argparse
import csv
from pathlib import Path


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    source = parser.add_mutually_exclusive_group(required=True)
    source.add_argument("--layout", choices=("identity", "serpentine"))
    source.add_argument("--map", type=Path, help="CSV with pixel,key columns, indices 0..24")
    parser.add_argument("--rotate180", action="store_true")
    args = parser.parse_args()
    if args.map:
        rows = list(csv.DictReader(args.map.open(encoding="utf-8-sig", newline="")))
        if len(rows) != 25:
            parser.error("CSV must contain exactly 25 rows")
        try:
            pairs = [(int(row["pixel"]), int(row["key"])) for row in rows]
        except (KeyError, ValueError):
            parser.error("CSV needs integer pixel,key columns")
        if sorted(pixel for pixel, _ in pairs) != list(range(25)):
            parser.error("pixel must be a permutation of 0..24")
        mapping = [key for _, key in sorted(pairs)]
    else:
        mapping = [pixel if args.layout == "identity" else
                   (pixel // 5) * 5 + (4 - pixel % 5 if (pixel // 5) % 2 else pixel % 5)
                   for pixel in range(25)]
    if sorted(mapping) != list(range(25)):
        parser.error("key must be a permutation of 0..24")
    if args.rotate180:
        mapping = [24 - key for key in mapping]
    print("GUIDE_PIXEL_KEY_MAP = {" + ",".join(f"5'd{key}" for key in reversed(mapping)) + "}")
    print("DIN chain pixel0..24 -> logical key0..24:", ",".join(map(str, mapping)))


if __name__ == "__main__":
    main()
