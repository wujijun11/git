# Touch25 actual exported Gerber review

Reviewed the actual EasyEDA Pro export, read-only:

`C:\Users\asus\Desktop\Git\TangMega60K_Synth\hardware\touch25\Gerber_Touch25_C4_C6_18mm_R1_2026-10-09.zip`

- ZIP size: 54,830 bytes; 12 file entries.
- ZIP SHA-256: `796ccb39e2b18cb72ef80832254a5d7d71be6fff0c74f9dee4a8960d6979c42c`.
- Every extracted file was compared byte-for-byte with the actual ZIP entry.
- Geometry audit: **163 checks PASS; zero failed checks**.
- CSV/manifest crosscheck: **PASS**, MIDI notes 60 through 84 in order.

## Verified manufacturing data

| Item | Observed in the actual files |
| --- | --- |
| Outline | Closed four-edge rectangle, 290.000 × 105.000 mm |
| Layers | Top and bottom copper, top and bottom mask, top and bottom legend |
| Electrodes | 25 independent E00–E24 top-copper regions matching the manifest polygons |
| Connectivity | Each electrode, its plated transfer and corresponding connector pin form one connected component |
| Isolation | All 25 components remain independent; no geometric signal-network short or extra nominal copper component after drilling |
| Mounting holes | Six 3.2 mm NPTH; lower middle hole at x170/y100 mm |
| Transfer holes | Twenty-five 0.3 mm PTH, with 0.8 mm copper pads on both layers; nominal radial annulus 0.25 mm |
| Connector holes | Twenty-five 1.0 mm PTH, with 1.8 mm copper pads on both layers; minimum nominal annulus 0.40 mm |
| Electrode mask | No opening intersects any of the 25 electrode regions on either side |
| Transfer mask | No opening intersects the entire 0.8 mm diameter of any transfer pad on either side |
| Connector mask | Openings are present at connector pads; three pin-1 openings use the exported RoundRect macro |
| Paste | No top or bottom solder-paste file is present in the ZIP |
| Interface mapping | J1/J2/J3 have 8/8/9 signals, matching MIDI 60–84 and MPR121 ELE assignments in mapping.csv |

The exporter uses `%ADD11C,0.0*%` and zero-size flashes at transfer pads in the
mask layers. Circular zero-diameter apertures are permitted and have no image
effect under Ucamco's Gerber specification. Thus those commands do not create
mask openings. See [Ucamco Gerber specification, zero-size apertures](https://www.ucamco.com/files/downloads/file_en/456/gerber-layer-format-specification-revision-2024-05_en.pdf).

## Parser handling disclosed

The original audit script failed closed on a real, valid RoundRect aperture macro
used for the three square pin-1 mask openings. A separate review copy implements
only the exact observed macro and validates its definition/parameters; other
unsupported macros still fail closed. It also excludes the manufacturer's
readme `.txt` from drill-file parsing. The source project and original script
were not edited.

The copper files each contain six isolated 3.2 mm disks exactly coincident with
the six 3.2 mm non-plated drill holes. The review accounts for nominal drilling
by removing only circular flashes with exactly equal diameter and centre to an
NPTH hole. Twelve such disks are removed across the two layers; the nominal
remaining annulus is zero. No partial copper intersection is silently discarded.
This treatment is recorded explicitly in the JSON audit result.

## Limits and next physical checks

- This is a geometric review of exported manufacturing data, not a fabrication
  acceptance certificate. Drill registration, finished-hole tolerances, CAM
  clearance edits, mask thickness and printing tolerances are not simulated.
  The factory's online preview/CAM should preserve the separate NPTH/PTH files
  and tented transfer pads.
- The GUI native DRC was performed by the root agent. This reviewer did not
  independently operate the GUI DRC and does not substitute the 163 script
  checks for it.
- The legend files are present, but this actual-Gerber script does not perform
  a full silkscreen font/readability audit. The prior native-geometry review
  covered text minimum height/stroke and the moved mounting-hole label conflict.
- The audit verifies intended geometric connectivity and CSV mapping. It does
  not use a factory electrical test or measure a fabricated board.
- MPR121 settings, actual sensitivity, simultaneous touches, neighbouring-key
  crosstalk, EMI, long-hold release, I²C timing and end-to-end audio latency
  require assembled hardware. No pressure/velocity sensing or ≤10 ms latency
  claim is validated here.
- This passive panel has no VCC/GND/controller. Supply and digital buses for
  external MPR121 modules are wired separately. Use short, fixed electrode
  leads and a nonconductive support before calibrating.

## Reproduction

Run `audit_gerber_independent.py actual_gerber --manifest <design_manifest.json>
--output actual_gerber_audit.json` from this review directory. Run
`package_crosscheck.py` to recheck the ZIP bytes and mapping. The resulting JSON
files contain the detailed checks and per-file hashes.
