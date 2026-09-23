# Piano parameter attribution

## Current four-region eight-partial model

`piano_eight_profiles.json` and the current `polar_lane*.hex` / `polar_ratios.hex`
derive from C4v12, A4v12, C5v12 and C6v12 of the same work, author, license and
pinned revision below. Every source WAV SHA256 and trimmed onset are recorded
in the JSON. The source FLAC URLs are the pinned repository's
`Samples/C4v12.flac`, `Samples/A4v12.flac`, `Samples/C5v12.flac`,
`Samples/C6v12.flac`.

Changes: lossless PCM24 reference decoding, offline extraction of eight
inharmonic sinusoidal components per region, amplitude/phase approximation
with 32 records per component, level calibration, and fixed-point coefficient
quantization. Only these coefficients are used by HDL. No source PCM, noise
recording, attack recording or recorded impulse response enters the FPGA.
Source recordings are separately labelled reference listening material.
See `docs/八成分分区钢琴.md` for scope and reproducible commands.

## Historical single-A4 model

The compact I/Q control model `piano_a4_iq.json` was derived from **Salamander
Grand Piano v3**, **Alexander Holm**, Yamaha C5, sample `A4v8.flac`.
Source: https://github.com/sfzinstruments/SalamanderGrandPiano
Pinned source revision: `3382bf9496bba2486f5ab0de55a264d1dfc38404`.
License: Creative Commons Attribution 3.0,
https://creativecommons.org/licenses/by/3.0/ ; see LICENSE-Salamander.txt.

Changes: eight slowly varying stereo sinusoidal I/Q components were fitted
offline; converted to piecewise-linear amplitude/phase and quantized into HDL
parameter ROM. This is NOT a full note PCM recording, soundfont, or waveform
playback buffer. It does not contain the source recording's residual/noise.
Derivative ROMs and demo audio retain this attribution and CC BY 3.0 notice.

Decoded source WAV SHA256:
`8f5dd81d8cf7188e8b1622cf15593af357d0f164aba9130b89a5f200a2bbdc4b`.
Offline Python generation uses numpy; real-time generation uses HDL only.
Only A4 at one velocity was modeled. Transposition does not recreate every
key's real string stiffness, hammer spectrum, or velocity-dependent timbre.
