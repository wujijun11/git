# Router payload-select optimization: integration equivalence

[Actual ModelSim summary](router_performance_equivalence_20261014_200638_461a1134/summary.json) reports PASS for three positive seeds and the deliberate negative-oracle check. ModelSim Intel FPGA Starter Edition 2020.1 was launched using Windows PowerShell 5. Compilation and each positive simulation have zero errors and zero warnings.

The old router was frozen before changes by copying its exact source and renaming only the module. Original source SHA256: `70da11f8430ff9176a1ffb77cf0aa20a1242de2cc6177a6cb66aec31eea65dc0`.

The candidate tested here is the real isolated build candidate's router:

`verification/timing-margin-20261014/candidate_payload_select_20261014_200303_4e91cfd8/rtl/control/remote_command_router.v`

Its SHA256 is `4f73a24b85b8755bc456a7398997492f56b136e74419c93c9963bcd4e93e6a86`. The candidate directory was only read, not edited. The TB's pending-select wiring matches that candidate's `rtl/instrument_full_system.v`: only the performance opcode/payload select uses `performance_pending`; command-valid and local-ready still use the reset-gated `performance_valid`.

Each lane contains its own real `performance_controller` instance compiled from the same current production source. The old lane uses the frozen router and `performance_valid` for selection; the new lane uses the candidate router and `performance_pending` for selection. Both receive the same external command/local/panic-inhibit/reset, record, and backpressure inputs, while each router receives status/readback from its own controller. A 1,024-bit packed comparison includes every shared public output. Every clock additionally compares row-valid/clear flags, selected/committed/running score metadata, ownership/held-note metadata, timer state, and uploaded RAM data for marked rows. Independent expected ACK/status and upload-epoch assertions check directed behavior.

`SCORE_CAPACITY=8`, `RECORD_CAPACITY=4`, and `CLK_HZ=1000` are simulation-only parameter overrides. No production parameter or RAM capacity was reduced.

Three seeds (`471833`, `94177`, `123456789`) each run 10,000 random clocks plus directed cases, for 31,044 checked clocks total. Their aggregate coverage is 5,719 accepted remote commands, 9,643 local actions, 5,696 ACK handshakes, 2,819 performance-command clocks, and 5,617 stalled ACK clocks. Each seed checks:

- Reset asserted asynchronously between clocks during `PERF_WAIT`, followed by reset release with no replayed transaction.
- Remote opcode 04 competing with a local opcode 04 action; remote priority and local-ready behavior are checked.
- Real-router score upload/commit, missing/reused upload rejection, playback/stop, event recording and panic controls.
- Strict adjacent controller 06→07 and 07→06 edges, including bulk bitmap clear, the final row, next-epoch write preservation, and repeated-commit rejection. These adjacent-controller cases use a shared direct command input only while both routers are idle, because UART packet routing cannot generate successive controller-clock commands.
- Fixed-seed local/remote traffic, panic inhibition, invalid requests, and response/note/expression/audio-event backpressure.

The negative self-test deliberately corrupts the comparison at clock 10; the runner verifies the exact output-mismatch Fatal at 96 ns and rejects that case as expected despite ModelSim returning exit code zero. Each positive requires a final whole-suite PASS marker and no Fatal/Error log lines.

Source fingerprints are captured before copy, required to equal their copies, and rechecked for both current sources and snapshots after simulation. Runner original/current/snapshot fingerprints are also checked. The actual summary records every source path and fingerprint; `InputsUnchanged` and `RunnerUnchanged` are both true. The earlier coverage-guard harness run is retained: it completed all functional comparisons but expected eight adjacent commit stimuli when only seven had been generated. An additional repeated-commit rejection stimulus corrected that test coverage count; the final accepted run uses the amended TB.

Re-run against an isolated candidate using:

```powershell
.\scripts\test-modelsim-router-performance-equivalence.cmd -RouterSource 'C:\path\to\candidate\rtl\control\remote_command_router.v'
```

Without `-RouterSource`, the driver tests the current production router after that candidate is promoted. This test proves RTL integration behavior; matching post-route timing results and physical measurements remain separate evidence.
