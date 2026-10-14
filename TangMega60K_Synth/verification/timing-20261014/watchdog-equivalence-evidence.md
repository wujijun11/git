# Watchdog timing optimization: sequential equivalence

Actual simulator: ModelSim Intel FPGA Starter Edition 2020.1. Commands were launched using Windows PowerShell 5 to avoid the known PowerShell 7 / 32-bit simulator DLL relocation issue. No shared ModelSim work library or GUI was changed.

The frozen reference contains the already-corrected first NoteOn / final NoteOff expiry behavior. Its original production source SHA256 is `ae4c4a74e39d60b036c928b2813a6813cb2406f568fb4debe85b1cfb20ed4b13`. The optimized source SHA256 tested here is `7bb684532e012bd450adddc3b1a97e59073b8d80ea9a8c52cce4bb84b7be16d7`.

The new test checks all 57 output bits and the full 128-bit ownership mask after every clock. A separate transaction ledger applies accepted note commands and acknowledged forced NoteOff events, then checks ownership independently of either RTL's scan/reduction implementation. It also checks stalled event stability and timeout-count transitions.

Both actual runs passed:

- Baseline reconstructed byte-for-byte from the frozen reference: [summary](watchdog_equivalence_20261014_194640_7ea7700c/summary.json).
- Optimized production versus frozen reference: [summary](watchdog_equivalence_20261014_194715_03d4ed52/summary.json).

The positive suite uses seeds `734921`, `94177`, and `123456789`, each with 20,000 random clocks and additional directed sequences. The optimized run checked 68,171 clocks total: 54,346 accepted commands, 15,392 forced release acknowledgements, 6,394 stall clocks, 17,061 heartbeat clocks, and 3,678 explicit-expiry clocks. Each seed covers all 128 note indices for NoteOn, NoteOff, forced release, and same-note accepted NoteOn plus forced-off acknowledgement. The acknowledgement retains the existing final-assignment priority.

Directed cases cover first On plus expiry, final Off plus expiry, natural timeout and heartbeat suppression at the threshold, pending event backpressure, a late low-index note during release, and an accepted On at scan-end that requires another pass.

Compilation and all three positive simulations report zero errors and zero warnings. A separate deliberately corrupted comparison produces the exact expected `output mismatch cycle=10` fatal at 96 ns. ModelSim returns exit code zero even for that fatal, so the driver checks the actual fatal/error text and the final PASS marker, rather than trusting the exit code. That negative self-test is expected to report one error and is not a production failure.

Input source snapshots and current source fingerprints match before and after the optimized run. The earlier unsuccessful baseline harness run is retained as raw evidence: its only issue was placing the heartbeat stimulus one cycle beyond the timeout threshold; no DUT/reference mismatch occurred. The corrected baseline and optimized run use the same testbench hash.

After independent review, the runner's snapshot guard was strengthened: it now hashes each source before copying, immediately requires the copy to match, checks each snapshot again at completion, and records the runner's own original/current/snapshot SHA256. Baseline mode explicitly permits only the DUT to be rebuilt from the frozen reference, requiring the effective source and final DUT snapshot to equal the frozen original hash. The reference and testbench must still match the original copies.

This guard-only revision did not alter RTL or the testbench and was not used to rewrite the existing simulation summaries. Windows PowerShell 5 parsing reports zero errors. An independent [fingerprint audit](watchdog-equivalence-guard-audit.json) confirms all three recorded `Snapshot == CurrentBefore == CurrentAfter` groups still match the current project in both actual runs, all final snapshots match their expected hashes, and the baseline DUT's intentional replacement matches its frozen original. The runner version used by the actual simulations is preserved as [tested runner v1](watchdog-equivalence-tested-runner-v1.ps1), SHA256 `28fe151782f0ddfaa5538c0bd4570dc2f026da363d0a1142e3f14493b035788f`; the audit records the strengthened future runner's separate fingerprint. No simulation rerun was needed for this guard revision.

Re-run from the project directory:

```powershell
.\scripts\test-modelsim-watchdog-equivalence.cmd
.\scripts\test-modelsim-watchdog-equivalence.cmd -Baseline
```

This is RTL functional equivalence evidence. It does not establish FPGA post-route timing or hardware performance; those require the matching Gowin build and board measurements.
