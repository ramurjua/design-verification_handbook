# fpga_scope — status / TODO

Project-agnostic FPGA debug oscilloscope (RTL core + HTML/Python GUI), being
built in `utils/fpga_scope`. This file is the handoff point for resuming work.

## Current status: RTL written, testbench NOT passing yet — do not trust the RTL until this is green.

Everything below `source/` and `test/` elaborates cleanly in `iverilog` across
several parameter configurations (channel counts, widths, both modes), but the
behavioral testbench (`test/scope_tb.v`) still fails: the DUT's `scope_cmd_if`
never successfully parses a single valid command frame, in any test, across the
whole run. **Nothing has been verified end-to-end yet.**

### What's been ruled out

- Not an elaboration/connectivity bug — `scope_top` elaborates fine standalone
  with several parameter sets (see history; the throwaway `elab_check.v` used
  for that was deleted afterward, not worth recreating, `scope_tb.v` supersedes it).
- Found and fixed a real bug: `scope_cmd_if.v`'s UART tx-data-valid signal
  (`r_tx_dv`, was `w_tx_dv`) was blocking-assigned (`=`) inside a
  `posedge clk` block while driving another module's (`uart_tx`) own
  `posedge clk` logic — a same-edge blocking/non-blocking race. Fixed to `<=`
  throughout. Confirmed via grep that no other clocked always block in
  `scope_*.v` has a similar stray blocking assignment (function-local blocking
  assignment inside the `f_frame_width`/`f_channel_offset` functions in
  `scope_top.v` is correct/required Verilog and is not this bug).
- Tried adding an extra settle cycle in the testbench's `send_byte` task
  (suspected a similar race in the TB's own host-side `wait(w_host_tx_ready)`
  right after clearing `dv`) — **did not fix it**, so that was either not the
  (only) cause, or the fix was insufficient.

### Debugging breadcrumbs (read before re-diagnosing from scratch)

- Add back a debug tap on `dut.u_cmd_if.w_rx_dv` / `w8_rx_byte` /
  `r3_rx_state` (see git history of `test/scope_tb.v` around this point,
  or just re-add `always @(negedge clk) if (dut.u_cmd_if.w_rx_dv) $display(...)`)
  — this showed the DUT's own `uart_rx` receiving **corrupted byte values**
  (e.g. got `d5,80,c0` instead of the sent `AA,01,00,00,01` for `CMD_GET_INFO`),
  not simply "nothing received." That means bytes are arriving but garbled —
  point suspicion at bit-level timing/framing on the wire, not just handshake
  logic. Interestingly `CMD_SET_TRIGGER`'s bytes decoded with a plausible
  partial/shifted alignment (worth re-examining precisely) — could indicate an
  off-by-one in the RX byte cadence rather than pure noise.
- Reproduce with: from `utils/fpga_scope/`,
  `iverilog -g2005-sv -gstd-include -grelative-include -o /tmp/scope_tb.vvp test/scope_tb.v source/scope_top.v source/scope_trigger.v source/scope_ctrl.v source/scope_decimator.v source/scope_streamer.v source/scope_capture_buffer.v source/scope_cmd_if.v ../../modules/uart/source/uart_tx.v ../../modules/uart/source/uart_rx.v`
  then `vvp /tmp/scope_tb.vvp` from `test/` (it opens `scope_tb.vcd` there).
- Worth checking next: instantiate the host-side `uart_tx`/`uart_rx` pair
  standalone (mirroring `modules/uart/test/uart_tb.v`, which is known-good)
  against `scope_top`'s `uart_rx` and see if garbling reproduces with an even
  simpler stimulus (single byte, long idle gaps between bytes) — that would
  isolate whether it's back-to-back-byte timing or something more basic like a
  reset-timing mismatch between DUT and the testbench's host-side UART
  instances (e.g. DUT and host UARTs coming out of reset on different cycles
  relative to each other, so the DUT's `r_uart_tick` phase is offset from what
  the sender assumes — this is a real candidate and hasn't been checked yet).

### Root cause found (2026-08-17): pre-existing bug in shared UART modules, not new code

Isolated with a minimal testbench (`uart_tx`/`uart_rx` directly, no
`scope_cmd_if` involved at all, `p_data_buffer=1` on both): sending 3 bytes
back to back after reset, **byte 1 is corrupted, bytes 2 and 3 decode
correctly**. This reproduces the exact same corrupted value (`0xd5` for a sent
`0xAA`) seen in `scope_tb.v`. So:

- This is a **pre-existing latent bug in `modules/uart/source/uart_rx.v` /
  `uart_tx.v`**, not something introduced by the new fpga_scope RTL.
- It's specific to `p_data_buffer=1` (byte-at-a-time streaming mode) — the
  repo's own passing testbench (`modules/uart/test/uart_tb.v`) only exercises
  `p_data_buffer=4` and has long (~10us) idle gaps between transfers, so this
  never surfaced there.
- Working theory: both `uart_tx` and `uart_rx` free-run an internal preescaler
  tick counter from reset, uncorrelated with when `i_dv`/the start bit actually
  occurs. Since TX and RX share `clk`/`rst` in these tests their counters stay
  numerically in lockstep, which should make bit timing self-consistent
  regardless of phase — but the first transaction after reset behaves
  differently from later ones, which doesn't fully fit that theory yet.
  Suspect something reset-adjacent (a register not reflecting the free-running
  counter's settled state yet, or `st_idle`'s continuous
  `r16_data_index <= lp_max_data_bit` not yet having "soaked" for at least one
  full tick period before the first start bit arrives). Needs a bit-by-bit
  waveform trace (`gtkwave`, `/c/iverilog/gtkwave/bin` is on PATH) of the
  isolated repro to nail down precisely which bit(s) get mis-sampled and why.
- The isolated repro lives at (scratchpad, not committed):
  `uart_isolate_tb.v` — recreate it if needed, it's ~60 lines, mirrors
  `modules/uart/test/uart_tb.v`'s style with `p_data_buffer(1)` on both ends.
- **Practical workaround to unblock fpga_scope specifically**: send/expect one
  harmless dummy byte immediately after reset (before real traffic) to "use
  up" the bad first-byte slot, either in `scope_cmd_if`'s own reset sequence
  or documented as a host-side requirement. Only do this if fixing the root
  cause in `uart_tx`/`uart_rx` themselves turns out to be invasive — fixing
  the actual modules is preferable since other consumers of these modules
  could hit the same bug.

## Immediate next step (highest priority)

1. Get `test/scope_tb.v` passing. Don't move on to anything else until this is
   green — no GUI, no more RTL features, no docs polish.
2. Once green, commit on this branch (`fpga_scope`) with a message describing
   the fix, then continue.

## Design decisions already made (don't re-litigate without reason)

- Protocol is fully specified in `docs/protocol.md` — read this first, it's
  the contract both RTL and the future Python backend must implement.
- 8 separate `p_ch0_width`..`p_ch7_width` params (not a packed bus) — explicit
  user ask, for easy/error-free instantiation.
- 8 separate `i_ch0`..`i_ch7` 8-bit input ports on `scope_top` (not a flat
  64-bit bus) — same reasoning, explicit user ask.
- No build-time mode-enable parameters — user explicitly decided against this
  (see conversation): `scope_top` always instantiates both `MODE_SCOPE` and
  `MODE_STREAM` hardware. Runtime switching between them is via `CMD_SET_MODE`
  only. Do not reintroduce `p_enable_scope_mode`/`p_enable_stream_mode`.
- UART itself is always used byte-at-a-time (`p_data_buffer(1)`) on both TX
  and RX in `scope_cmd_if.v` — all the framing/variable-length-command
  complexity lives in `scope_cmd_if`'s own state machine, not in the UART.
- Streaming mode (`MODE_STREAM`) is **count-bounded bursts**
  (`CMD_STREAM_START` takes a 4-byte `sample_count`), not open-ended
  start/stop — this was a deliberate redesign after finding that an
  open-ended stream can't be reliably distinguished from a response frame at
  the byte level (raw sample data can legitimately contain any byte value,
  including the sync byte). See docs/protocol.md's "Stream mode" section for
  the full reasoning.
- `CMD_DUMP` streams `pre_trigger_count + post_trigger_count` samples (the
  values latched at the last `CMD_ARM`), not the full physical buffer depth.
- Buffer word width is NOT dumped/streamed as `channel_widths` bytes — see
  `docs/protocol.md`'s note that `(pre+post) * frame_bytes` must stay under
  65535 because `LEN` is a 16-bit field.

## Still to build (after the testbench is green)

- [ ] Get `test/scope_tb.v` fully passing (blocking everything else, see above)
- [ ] Hardware bring-up note / sanity checklist (this has never touched real
      hardware — UART timing especially should get a real FTDI/scope check
      before being trusted, per this repo's convention of being explicit about
      simulation-only vs hardware-tested status, c.f. `modules/uart/uart.md`)
- [ ] `source/scope_top.md` or similar per-module doc matching this repo's
      style (see `modules/uart/uart.md` for the format: short description,
      status line, source/testbench links, instantiation snippet)
- [ ] Python backend (`gui/backend/`): `protocol.py` (mirrors
      `docs/protocol.md` independently, pyserial-based), `app.py`
      (FastAPI + WebSocket was the plan going in, not yet decided/confirmed
      with the user — revisit before building)
- [ ] HTML/JS frontend (`gui/frontend/`) — plain HTML/JS/CSS, no Qt, no build
      step (explicit user requirement)
- [ ] Wire the GUI's mode selection (tabs/pages) to `CMD_SET_MODE`
- [ ] Root `README.md` index entry + `utils/utils.md` entry once there's
      something real to point to (do NOT add these while the core is unverified)
- [ ] Decide & document: FastAPI vs Flask vs plain http.server; REST-polling
      vs WebSocket for live status/streaming — this was assumed but never
      actually confirmed with the user
