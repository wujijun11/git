# Manufacturing export review

Review date: 2026-10-18 (Asia/Shanghai). **PASS** for the checks below. This is a read-only file-consistency review; no product or manufacturing source file was changed.

Sources: `C:/Users/asus/Documents/LCEDA-Pro/projects/AHCT125-LED-R1/`. Detailed coordinates, counts, native schematic part comparisons and hashes are in `manufacturing_review.json`.

## PCB and drills

- Board outline is a closed rectangle, X=0..40 mm and Y=-30..0 mm: **40 x 30 mm**.
- Plated through drill file contains **21 holes**: 12 vias plus 9 component holes.

| Drill diameter in exported file (mm) | Count | Interpretation |
|---:|---:|---|
| 0.29972 | 1 | Via |
| 0.30000 | 11 | Vias |
| 1.00000 | 2 | C3 capacitor leads |
| 1.10002 | 5 | J1 two pins and J2 three pins |
| 1.60000 | 2 | J3 terminal block |
| 3.20000 NPTH | 2 | Mounting holes |

The 0.29972 mm via differs from 0.30000 mm by 0.00028 mm (mil conversion rounding). The 1.10002 mm diameter is likewise effectively the intended 1.1 mm.

**`Drill_PTH_Through_Via.DRL` repeats the 12 vias already present in `Drill_PTH_Through.DRL`; it is a subset, not 12 additional holes.** This review confirms each of its diameter/coordinate triples occurs in the complete PTH file.

The exported component drill diameters resolve the earlier misleading component-pad API getter values: the native footprint and actual drill output agree at 1.0/1.1/1.6 mm; no drill-enlargement correction is needed.

## Top paste

`Gerber_TopPasteMaskLayer.GTP` contains **22 apertures**:

| Reference | Apertures | Export representation |
|---|---:|---|
| U1 | 14 | Oblong flashes |
| C1 | 2 | Rectangle flashes |
| C2 | 2 | Custom filled polygon regions |
| R1 | 2 | Custom filled polygon regions |
| R2 | 2 | Custom filled polygon regions |

The six custom polygon apertures are present at the corresponding component locations. This verifies that the R0603/C0805 negative automatic paste expansions did not remove their replacement top-paste FILL regions. All 16 automatic flashes and six regions are present in the exported manufacturing file.

## BOM and native placement file

- BOM and CPL contain the same **nine unique designators**, each with BOM quantity 1.
- Each exported BOM supplier part and manufacturer part matches the current native schematic instance attributes; each BOM footprint matches its CPL footprint.
- Five references are SMD (U1, R1, R2, C1, C2); four are through-hole (C3, J1, J2, J3). All nine rows are top-side, including the through-hole rows.
- All component centers fall inside the exported board outline.

| Ref | LCSC part | Manufacturer part | Mid X (mm) | Mid Y (mm) | Native CPL rotation |
|---|---|---|---:|---:|---:|
| C1 | C14663 | CC0603KRX7R9BB104 | 24mm | -12mm | 0 |
| C2 | C15850 | CL21A106KAYNNNE | 19mm | -8mm | 0 |
| C3 | C88853 | 10PX1000MEFC8X11.5 | 29mm | -7mm | 0 |
| J1 | C124375 | B-2100S02P-A110 | 3mm | -16mm | 90 |
| J2 | C124376 | B-2100S03P-A110 | 37mm | -18mm | 90 |
| J3 | C474906 | KF127-5.08-2P | 8.5mm | -5mm | 0 |
| R1 | C25804 | 0603WAF1002T5E | 12mm | -16mm | 90 |
| R2 | C23138 | 0603WAF3300T5E | 30mm | -20.54mm | 0 |
| U1 | C155176 | SN74AHCT125DR | 20mm | -18mm | 270 |

**Native CPL signs and rotations were retained.** In particular, U1 is 270 degrees; J1, J2 and R1 are 90 degrees. Negative Y coordinates agree with the exported board outline. No guessed orientation offsets, mirroring, or sign normalization was applied.

The files named `.csv` are the editor's native **UTF-16LE, tab-delimited** text, with a BOM. Native CPL extra CR line separators remain unchanged. This review parsed them as emitted; importing into a factory portal must still be checked for correct column detection.

## File identity

| File | SHA-256 |
|---|---|
| Gerber_AHCT125_LED_R1.zip | `ff1231a71da42265830669f89beb39aa31c08283d48180a0a21f38eae18b9032` |
| BOM_AHCT125_LED_R1.csv | `66fea025c0694ac6f7172c2de3a168520229c1d41ab7468f9a11cc6cfa3512e4` |
| CPL_AHCT125_LED_R1.csv | `4eb4894b3046822a958c3669a15ea75e399873408c1cf63e8108cfa7aeb9bb1c` |

## Limits

This review verifies the requested export geometry, drill and stencil counts, part identity, and BOM/CPL consistency. It does not establish physical operation, signal integrity, soldering yield, current factory component availability, or factory DFM/assembly approval. These are single-board 40 x 30 mm artifacts; the Gerber is not a 2 x 2 production panel.

## Native XLSX delivery cross-check

The separately exported native BOM and CPL `.xlsx` files were opened read-only using Python standard-library ZIP/XML parsing, with shared strings and inline strings resolved. **PASS:** every non-empty row, header, and data cell exactly matches its corresponding native CSV. Only completely empty trailing/interleaved rows were ignored. No coordinates, units, signs, or angles were normalized.

| File | Data rows | Columns | Data cells compared | Header cells compared | Differences |
|---|---:|---:|---:|---:|---:|
| BOM_AHCT125_LED_R1.xlsx | 9 | 10 | 90 | 10 | 0 |
| CPL_AHCT125_LED_R1.xlsx | 9 | 18 | 162 | 18 | 0 |

Across both workbooks this checks **252 data cells and 28 header cells**, including all nine designators, LCSC/manufacturer part numbers, footprints, all placement coordinates (Mid/Ref/Pad), layer, SMD flags and rotation. Row order is identical; no formulas are present in either data worksheet. U1 remains rotation 270 degrees, and all negative Y values and `mm` strings are preserved exactly. The previously reviewed Gerber/CSV hashes were checked again and remain unchanged.

**Delivery preference:** use `BOM_AHCT125_LED_R1.xlsx` and `CPL_AHCT125_LED_R1.xlsx` for the factory upload; retain the native CSV files as reference evidence. XLSX avoids having the portal infer the UTF-16/tab-delimited CSV dialect. Final factory import preview still needs to show the expected nine rows and correct columns.

| XLSX file | SHA-256 |
|---|---|
| BOM_AHCT125_LED_R1.xlsx | `4ba25a9e1b9e5b64fe6a8897ce07297cdcd02b641226959c6dc5dc57aab7a8b7` |
| CPL_AHCT125_LED_R1.xlsx | `ee6f63351e309ccec3c65d3f628cc3beb1686b794b69350648b957488dd7b245` |
