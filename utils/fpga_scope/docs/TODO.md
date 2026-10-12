# fpga_scope — status and roadmap

Project-agnostic FPGA debug oscilloscope: RTL core driven over UART, Python
backend and browser GUI. User-facing documentation is in
[`../fpga_scope.md`](../fpga_scope.md) and
[`integration.md`](integration.md); this file tracks status, decisions and
remaining work.

## Current status (2026-10-10): working on hardware

The whole chain (RTL core, UART, `protocol.py`, backend, GUI) has run on a
real board. See "Verification record" for exactly what was tested.

## What exists

- `source/` — RTL core (`scope_top` and its sub-modules). Depends on
  `modules/uart/source/uart_tx.v` and `uart_rx.v`.
- `test/scope_tb.v` — RTL testbench, 6 tests, run with `python run.py`.
- `example/scope_example_top.v` — top level with self-generated signals
  (two squares, ramp, triangle, slow ramp) on 5 channels.
- `gui/backend/protocol.py` — host side of `docs/protocol.md` (`ScopeClient`).
- `gui/backend/scope_cli.py` — command-line tool, used for bring-up.
- `gui/backend/session.py`, `app.py` — connection/job handling and the
  FastAPI server (REST + WebSocket).
- `gui/backend/sim_device.py` — simulated core selectable as port `sim`.
  A stand-in for GUI work, NOT a reference model of the RTL.
- `gui/frontend/` — the web page: Scope and Stream tabs, per-channel
  trigger, hover readout, CSV download; Y axes, per-channel display
  settings, zoom, cursors, measurements, saved configurations
  (`scope_math.js` holds the maths, `tests/` its tests).
- `docs/protocol.md`, `docs/integration.md`, `docs/gui.md`.

## Verification record

- **Simulation**: `test/scope_tb.v` passes (GET_INFO, SET_TRIGGER, ARM +
  capture, DUMP, SET_MODE + STREAM_START, pre-trigger holdoff). Backend: 41
  unit tests (`test_protocol`, `test_scope_cli`, `test_app`) against scripted
  bytes and the simulated device. The example design was simulated once with
  an ad hoc testbench (not committed) and its replies decoded by
  `protocol.py`.
- **GUI display features (2026-10-12), simulated device only**:
  `test_frontend.py` runs `gui/frontend/tests/` in a headless browser: the
  display maths (`unit.html`) and the real page driven against the `sim`
  port (`e2e.html`); `test_app.py` covers the configuration store. Not yet
  used against a board.
- **Hardware, 2026-10-10**: `example/scope_example_top.v` on the Drone
  FPGA_SOM board (Spartan-7 xc7s50, 25 MHz clock, `p_uart_preescaler` 217,
  CP210x adapter, 115200 baud).
  - GET_INFO / GET_STATUS / SET_TRIGGER: 0 failures in 1000 each.
  - 50/50 captures (pre 100, post 300) fully correct; full-buffer (512/512),
    falling-edge, bit-select, AND-combine and decimation-4 captures correct.
  - Stream bursts consistent at decimation 1, 100, 217, 1000 and 65535.
  - GUI driven in headless Chrome against the real port: connect, arm,
    capture plot, stream, stop and disconnect all work.
  - Only this one board, clock and baud rate have been tested.
- **Bugs the first hardware run found, both fixed and re-tested on the board**:
  - The old UART modules only worked with TX and RX prescalers in lockstep;
    against a real adapter 1-6 % of commands were lost. `uart_tx`/`uart_rx`
    were reworked (see `modules/uart/uart.md`, `uart_async_tb.v`).
  - `scope_ctrl` accepted a trigger before the pre-trigger window had filled,
    so the start of a dump was stale buffer contents. Fixed with a holdoff,
    covered by Test 6 in `scope_tb.v`.

## Design decisions already made (don't re-litigate without reason)

- Protocol is fully specified in `docs/protocol.md` — read this first, it's
  the contract both the RTL and the Python backend (`gui/backend/protocol.py`)
  implement.
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
- `CMD_SET_MODE` (and `CMD_SET_TRIGGER`/`CMD_ARM`) require the scope to be
  idle (`SCOPE_ST_IDLE`, not `SCOPE_ST_DONE`) — a completed capture must be
  explicitly `CMD_ABORT`ed (or re-armed) before switching modes or arming
  again. This is intentional per `docs/protocol.md`, not a bug.
- Backend stack: FastAPI, REST for commands plus one WebSocket for pushed
  state and data (confirmed by the user 2026-10-10). Frontend: plain
  HTML/JS/CSS, no Qt, no build step (explicit user requirement).
- After `CMD_ARM` the core ignores triggers until the pre-trigger window is
  full, so a dump never contains samples from before the arm.
- GUI configuration (2026-10-12): selecting signed/unsigned per channel is
  one of the most important settings for the user. Configurations are JSON
  on disk, must be loadable through a file dialog, and must be writable by
  hand, so `normalizeConfig` accepts partial files and reports what it
  could not use instead of rejecting the file.

## GUI display improvements (brainstormed and implemented 2026-10-12)

Asked for after using the scope on a real project: analog values could only
be read with the cursor. Everything here is GUI only (frontend, plus a small
config store in the backend); no RTL or protocol change. Described for the
user in `docs/gui.md`. Verified against the simulated device only.

First group:

- [x] Y axis per lane: ticks, gridlines and labels, with a range per signal
      (full scale, auto-fit to the visible samples, or manual min/max).
- [x] Per-channel signed (two's complement), fraction bits (Q format), gain
      and offset; axis, tooltip and CSV show the scaled value.
- [x] Per-channel name and unit.
- [x] X zoom and pan on a finished capture or a stopped stream.
- [x] Save and reload the configuration: automatically in the browser, as
      named JSON files on disk through the backend (`gui/configs/`), and
      from/to any JSON file through the browser's file dialog. A
      hand-written file only needs the settings it changes.

Second group:

- [x] Measurement cursors (dt, 1/dt, dY per signal).
- [x] Show/hide a channel and choose its lane height.
- [x] Linear interpolation as an alternative to the stepped trace, and
      sample markers when zoomed in.
- [x] Combine channels into one wider signal (a 16-bit value split over two
      8-bit channels), up to 32 bits.

Later group:

- [x] Statistics over the visible window (min, max, mean, peak-to-peak).
- [x] Overlay: several signals in one lane on a shared Y axis.
- [x] Save a capture to a file, load it back, keep one as a reference trace.
- [x] Bus display for multi-bit signals that are not analog (value written
      inside a band).
- [x] Raw value format per channel in the readout (decimal, hex, binary).
- [x] One lane per bit of a multi-bit signal (asked for during the work).

Left over from this batch:

- [ ] Try it against the board, on real signals.
- [ ] `img/gui_scope.png` and `img/gui_stream.png` in `fpga_scope.md` still
      show the GUI as it was before.

Not GUI only, so not part of this batch:

- [ ] Trigger on a level (value above/below a threshold). The core only
      triggers on one selected bit of a channel (level or edge), so this
      needs a comparator in `scope_trigger` and a `CMD_SET_TRIGGER` payload
      change (doc, `scope_defs.vh`, `scope_cmd_if.v`, `protocol.py`,
      `sim_device.py`, `scope_tb.v`, then the board).

## Still to do

- [ ] Use it on real signals: replace the example in the Drone FPGA_SOM
      design with a `scope_top` fed by the IMU SPI lines and valid flag.
- [ ] GUI: re-arm ("normal"/auto) capture mode.
- [ ] GUI stream view: consecutive bursts are not contiguous in time (the
      host needs a moment between `CMD_STREAM_START`s), so slow signals show
      a small jump at every burst boundary. Larger bursts make it rarer.
- [ ] Try other configurations: a faster baud rate, a 100 MHz clock, wide
      frames (8 channels x 8 bits), another USB-UART adapter.
- [ ] A committed testbench that drives the RTL with frames produced by
      `protocol.py` (today that cross-check was done once by hand).
- [ ] Website: generate the HTML for `fpga_scope.md` and the docs (now also
      `docs/gui.md`) with
      `web/generate_srcs.py`, publish, and add the page to `publish/index.html`
      and `publish/nav.html` by hand (needs `pandoc`).
