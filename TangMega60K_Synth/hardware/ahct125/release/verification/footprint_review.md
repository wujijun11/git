# AHCT125 LED R1 footprint review

Reviewed on 2026-10-18 (Asia/Shanghai). This was a read-only inspection of the editor's exported API state, native project records, and installed EasyEDA Pro 4.1.60 API documentation. No footprint, pad, hole, or paste parameters were changed by this review.

## Sources

- Native project: `C:/Users/asus/Documents/LCEDA-Pro/projects/AHCT125-LED-R1/`
- PCB: `pcb/PCB1.epcb2`
- Schematic and its embedded libraries: `sch/Schematic1/P1.esch2`
- API observation: `../references/layout.json`
- Documentation evidence: `../references/agent-EPCB_LayerId.json`, `agent-PCB_PrimitivePad-modify.json`, `agent-IPCB_PrimitivePad-setState_SolderMaskAndPasteMaskExpansion.json`, `agent-IPCB_PrimitiveSolderMaskAndPasteMaskExpansion-None.json`.

Line numbers below refer to the native files at the time of inspection. Subsequent editor saves may change them.

## Paste expansion is intentionally disabled where custom apertures exist

`layout.json` reports `topPasteMask=-3937` and `bottomPasteMask=-3937` for the two C2 pads and both pads of R1/R2. Looking only at the pad API state would suggest missing paste apertures. The embedded native footprints explain the setting: these footprints contain explicit **top paste layer FILL polygons**, which replace the automatic pad-shaped apertures.

The installed `EPCB_LayerId` documentation confirms **layer 7 = top paste**, layer 8 = bottom paste, layer 5 = top solder mask, layer 6 = bottom solder mask. Thus the FILL records below belong to the manufacturing paste layer, not silk or copper.

| Footprint / placed references | Native PCB records | Embedded schematic records | Evidence |
|---|---|---|---|
| R0603 / R1, R2 | FILL `e5/e6`, lines 377/378; PAD `e7/e8`, lines 389/390 | FILL lines 428/429; PAD lines 440/441 | Two solid FILL polygons on layer 7; each PAD has top/bottom paste expansion `-3937.0080000000003` |
| C0805 / C2 | FILL `e17/e18`, lines 468/469; PAD `e15/e16`, lines 483/484 | FILL lines 519/520; PAD lines 534/535 | Two solid FILL polygons on layer 7; each PAD has the same disabled automatic paste expansion |

For example, the C0805 FILL `e17` starts with a polygon point `[-67.125,-25.197]`; its companion `e18` starts at `[67.125,25.197]`. Both have `layerId:7`, `fillStyle:"SOLID"`. Their non-rectangular contours include inward notches; these are custom stencil apertures rather than an absent stencil.

This replacement construction already exists in **both** the schematic's embedded library and the PCB's embedded library, so the negative value did not originate in the recent component-placement API call.

### API state for all nine placed components

| References | Top/bottom solder mask expansion (mil) | Top/bottom paste expansion (mil) | Interpretation |
|---|---|---|---|
| C1 | 2 / 2 | 0 / 0 | Standard automatic SMD paste apertures |
| C2 | 2 / 2 | -3937 / -3937 | Explicit layer-7 FILL apertures; keep automatic paste disabled |
| R1, R2 | 2 / 2 | -3937 / -3937 | Explicit layer-7 FILL apertures; keep automatic paste disabled |
| U1 | 2 / 2 | 0 / 0 | Standard automatic SMD paste apertures |
| C3, J1, J2, J3 | 2 / 2 | 0 / 0 | Through-hole pads; API documentation says paste expansion settings do not apply to through-hole pads |

**Recommendation:** retain the original custom-paste construction. Do not set C2/R1/R2 paste expansion to zero merely because the pad API reports a negative value; doing so can add automatic pad-shaped openings over the custom geometry. The Gerber top-paste output still requires final inspection to verify that the custom FILL polygons were included and correctly transformed with their placed components. Expected SMD references are U1, R1, R2, C1, C2 (22 pads in total); custom polygon contours may remain visible in the output.

## Through-hole API getter appears to report a tenth of the native diameter

The native embedded footprints contain appropriate full-size drill dimensions. The `layout.json` component-pad API values are exactly one tenth of them:

| References | Native `hole.width/height` (mil) | Native nominal drill (mm) | API-reported hole width/height (mil) |
|---|---:|---:|---:|
| J1, J2 | 43.308 | 1.1000 | 4.3308 |
| J3 | 62.992 | 1.6000 | 6.2992 |
| C3 | 39.37 | 1.0000 | 3.937 |

Native PCB evidence:

- J1 footprint `HDR-TH_2P-P2.54-V-M-1`: PAD `e6/e7`, lines 520/521, `hole:{"holeType":"ROUND","width":43.308,"height":43.308}`.
- J2 footprint `HDR-TH_3P-P2.54-V-M-1`: PAD `e10/e11/e12`, lines 642–644, diameter 43.308 mil.
- J3 footprint `CONN-TH_P5.08_KF127-5.08-2P`: PAD `e21/e22`, lines 692/693, diameter 62.992 mil.
- C3 footprint `CAP-TH_BD8.0-P3.50-D0.6-FD`: PAD `e12/e13`, lines 735/736, diameter 39.37 mil; centers at ±68.9 mil give the expected 3.5 mm lead spacing.

No placed pad-dimension override was found in the PCB section at inspection time; the component instances refer to these embedded footprints and define pad-net mappings.

**Recommendation:** do not enlarge holes based on the component-pad getter alone. Native file evidence supports an API getter scaling discrepancy, but the final manufacturing authority is the exported drill file. Verify Excellon drill tool diameters near 1.0, 1.1 and 1.6 mm, and compare them with the actual connector/capacitor drawings before ordering. This review did not yet inspect an exported drill file and does not certify its output.

## Documented correction API, if output verification later proves a real defect

The official CLI documents:

```ts
eda.pcb_PrimitivePad.modify(primitiveId, {
  solderMaskAndPasteMaskExpansion: {
    topSolderMask: 2,
    bottomSolderMask: 2,
    topPasteMask: 0,
    bottomPasteMask: 0
  }
})
```

The component-pad objects returned by `pcb_PrimitiveComponent.getAllPinsByPrimitiveId(...)` inherit pad state operations, including:

```ts
pad.setState_SolderMaskAndPasteMaskExpansion(value);
await pad.done();
```

These are documentation-only examples, **not applied changes**. A safe redesign of a custom-paste footprint would require changing/removing its explicit paste FILL polygons together with any automatic-aperture setting, then regenerating and inspecting Gerber. Changing the pad setting alone is not a safe correction for this project.

The API documents `setState_Hole(...)`, but a drill correction must only follow an actual exported-drill defect. Its input units/round-trip behavior must be checked before any setter is used, given the getter discrepancy observed above.
