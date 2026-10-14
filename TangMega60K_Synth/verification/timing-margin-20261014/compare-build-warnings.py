"""Compare actual tool warnings while normalizing only snapshot root spelling."""
import json
import re
import sys
from collections import Counter
from pathlib import Path

baseline = Path(sys.argv[1]).resolve()
candidate = Path(sys.argv[2]).resolve()


def warnings(snapshot):
    text = (snapshot / "gowin-build.log").read_text(encoding="utf-8-sig", errors="replace")
    roots = [str(snapshot), snapshot.as_posix()]
    items = []
    for row in re.findall(r"^WARN\s+.*$", text, re.MULTILINE):
        for root in roots:
            row = row.replace(root, "<SNAPSHOT>")
        items.append(row.strip())
    return Counter(items)


before, after = warnings(baseline), warnings(candidate)
result = {"baseline": str(baseline), "candidate": str(candidate),
          "baselineCount": sum(before.values()), "candidateCount": sum(after.values()),
          "unchangedAfterRootNormalization": before == after,
          "added": list((after - before).elements()), "removed": list((before - after).elements()),
          "normalization": "Snapshot directory roots only; text, codes and source line numbers retained."}
(candidate / "warning-comparison.json").write_text(json.dumps(result, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
print(json.dumps(result, ensure_ascii=False, indent=2))
