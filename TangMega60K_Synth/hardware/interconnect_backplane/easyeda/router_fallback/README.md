# Two-layer fallback routing plan

No CAD document was changed by this task. `routing_plan.json` uses millimetres, X right and Y down. Convert coordinates to EDA mil by `x / .0254`, `-y / .0254`.

The plan has 348 tracks (342 new + 6 fixed corrected power tracks) and 15 vias (0.7 mm outer diameter, 0.3 mm drill). Skip tracks marked `fixed: true` if the parent already installed all six corrected power segments.

Critical correction: the former single bottom GND segment J8.2 to J9.2 crossed the J9.1 +5V through-hole pad. Replace it with the 1.8 mm bottom dogleg through Y=40 mm before importing generated tracks. The three existing +5V top segments remain at Y=51 mm.

Exact pairwise geometry checks found minimum different-net copper clearance 0.2244218 mm, exceeding 0.20 mm. Independent graph checking connects all 42 wired pads in their intended 15 separate nets; no isolated planned copper was found. Board-edge and NPTH copper distances exceed 0.30 mm. This does not replace native EDA DRC or manufacturing verification.
