# fpga_scope — status and roadmap

Project-agnostic FPGA debug oscilloscope: RTL core driven over UART, Python
backend and browser GUI. User-facing documentation is in
[`../fpga_scope.md`](../fpga_scope.md) and
[`integration.md`](integration.md); this file tracks status, decisions and
remaining work.

## Current status (2026-10-12): working on hardware

The whole chain (RTL core, UART, `protocol.py`, backend, GUI) has run on a
real board, including the controls (host-writable outputs, added
2026-10-12), which the user tried there by hand. See "Verification record"
for exactly what was tested.

## What exists

- `source/` — RTL core (`scope_top` and its sub-modules). Depends on
  `modules/uart/source/uart_tx.v` and `uart_rx.v`.
- `test/scope_tb.v` — RTL testbench, 11 tests, run with `python run.py`.
- `test/scope_wide_tb.v` — the core built with 16-bit channels, 4 tests, run
  with `python run_wide.py`.
- `example/scope_example_top.v` — top level with self-generated signals
  (two squares, ramp, triangle, slow ramp) on 5 channels, plus control 0
  looped back on 2 more.
- `gui/backend/protocol.py` — host side of `docs/protocol.md` (`ScopeClient`).
- `gui/backend/scope_cli.py` — command-line tool, used for bring-up.
- `gui/backend/session.py`, `app.py` — connection/job handling and the
  FastAPI server (REST + WebSocket).
- `gui/backend/sim_device.py` — simulated core selectable as port `sim`.
  A stand-in for GUI work, NOT a reference model of the RTL.
- `gui/frontend/` — the web page: Scope and Stream tabs, per-channel
  trigger, hover readout, CSV download; Y axes, per-channel display
  settings, zoom, cursors, measurements, saved configurations, recording
  of a whole stream; controls shown as buttons, switches and values
  (`scope_math.js` holds the maths, `tests/` its tests).
- `docs/protocol.md`, `docs/integration.md`, `docs/gui.md`.

## Verification record

- **Simulation**: `test/scope_tb.v` passes (GET_INFO, SET_TRIGGER, ARM +
  capture, DUMP, SET_MODE + STREAM_START, pre-trigger holdoff, and the
  controls, below). Backend: 73 unit tests (`test_protocol`,
  `test_scope_cli`, `test_app`) against scripted bytes and the simulated
  device. The example design was simulated once with an ad hoc testbench
  (not committed) and its replies decoded by `protocol.py`.
- **Controls on the board (2026-10-12)**: the user tried the buttons from
  the GUI against the rebuilt bitstream and reports they work. Not written
  down: which control kinds, and whether a design reacting to `o_controlN`
  was observed or only the write and read-back. The Drone FPGA_SOM `top.v`
  of that day has the current RTL (protocol version 2) with all eight
  control outputs left open, so against that design a working button shows
  the command path and the register over the real UART, not an output
  driving logic. The example's loop-back (ch5/ch6) has not been run on a
  board.
- **Controls (2026-10-12), simulation**:
  - RTL, `scope_tb.v` tests 7 to 11: write and read back; one update pulse
    per accepted write and only on that control, also for a repeated value;
    bad index, short payload and bad checksum change nothing; a write while
    armed does not disturb the capture; a write during a stream burst is
    dropped and the next one is taken; reset clears. A monitor checks on
    every clock that a control only ever holds its old or its new value.
    Each of these was seen to fail with the RTL broken on purpose (length
    check, index check, update pulse, reset, read byte order).
  - `protocol.py` against the same byte vectors; `sim_device.py`,
    `session.py` and `app.py` including writes while a capture is armed and
    while a stream runs (seen to fail with the exchange lock removed);
    `scope_cli.py control` / `controls`.
  - GUI: `unit.html` for the scaling and limits of a typed value, `e2e.html`
    for buttons, switches, values, the configuration, writes during a
    stream, and a core without controls (`sim-v1`).
  - The example's loop-back of control 0 on ch5/ch6 was simulated once with
    an ad hoc testbench (not committed).
- **GUI display features (2026-10-12), simulated device only**:
  `test_frontend.py` runs `gui/frontend/tests/` in a headless browser: the
  display maths (`unit.html`) and the real page driven against the `sim`
  port (`e2e.html`); `test_app.py` covers the configuration store.
- **GUI display features on the board (2026-10-12)**: tried by hand by the
  user, they work. No written record of which settings were exercised.
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
- 8 separate `i_ch0`..`i_ch7` input ports on `scope_top` (not a flat
  64-bit bus) — same reasoning, explicit user ask.
- Port width is the parameter `p_channel_max_width` (1-16, default 8), the
  same for all eight ports — user's choice (2026-10-14) over fixed 16-bit
  ports, so existing instantiations keep working unchanged. For the same
  reason the ports kept the `i_chN` names although the naming convention
  would make them `ip_chN`.
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
- Not wanted (user, 2026-10-12): a re-arm ("normal"/auto) capture mode in
  the GUI, and website pages for fpga_scope (`publish/`). Do not add them
  back to the list.

- Controls (user, 2026-10-12): the core always has all 8, each 32 bits
  wide, with no parameter for their number or width, so there is nothing to
  keep in step between the RTL and the GUI. The GUI decides what each one is
  (button, switch, value) and how many are in use, from none to 8; a project
  with none configured must work exactly as before. One mechanism for
  buttons and values: a register per control plus a one-clock update pulse
  on every write. Separate `o_controlN` ports, like the channels. The only
  thing to keep in step is an old bitstream, which reports
  `protocol_version` 1 and gets its controls greyed out.
- Controls are named "control", not "ctrl", in the RTL: `scope_ctrl` and
  the `w_ctrl_*` wires are the capture state machine, an unrelated thing.

## GUI display improvements (brainstormed and implemented 2026-10-12)

Asked for after using the scope on a real project: analog values could only
be read with the cursor. Everything here is GUI only (frontend, plus a small
config store in the backend); no RTL or protocol change. Described for the
user in `docs/gui.md`. Verified against the simulated device, then used on
the board by the user (see "Verification record").

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

Left over from this batch, done later the same day:

- [x] Try it against the board (done by the user).
- [x] `img/gui_scope.png` and `img/gui_stream.png` retaken against the
      simulated device.

Added afterwards (2026-10-12):

- [x] Stream tab: Start recording / Stop recording. The plot only ever held
      the last "Samples on screen", so nothing kept a whole stream. A
      recording keeps every burst in the browser and downloads one CSV on
      stop, with a `burst` column because bursts are not contiguous in time.
      Simulated device only so far.

## Controls (implemented 2026-10-12)

Asked for by the user: buttons with configurable names that the FPGA sees as
outputs, then extended to buttons and fields that send values (a speed
command). A protocol change, so it touched the whole chain; described in
`docs/protocol.md` ("Controls"), `docs/integration.md` (step 5) and
`docs/gui.md`.

- [x] RTL: `CMD_CONTROL_WRITE` / `CMD_CONTROL_READ` in `scope_cmd_if`,
      `o_control0`..`o_control7` and `o_control_update` on `scope_top`,
      `protocol_version` 2.
- [x] `protocol.py`, `sim_device.py` (and `sim-v1`, an unlisted port that
      behaves as a version 1 core), `session.py` (a write goes in between
      two exchanges of a running capture or stream job), `app.py`
      (`/api/controls`), `scope_cli.py`.
- [x] GUI: per-control settings in the configuration, widgets above the
      plot, read-back after every write and on connect.
- [x] Example design: control 0 looped back on ch5 (low byte) and ch6
      (toggles on every write), so the first board test needs no extra
      hardware.
- [x] Try it on the board: buttons tried by the user from the GUI, working
      (see "Verification record" for what that does and does not cover).
- [ ] On the board, see a design react to a control: the example's
      loop-back on ch5/ch6, or a control wired into the Drone design.
- [ ] No timeout: a control keeps its value when the host goes away. An
      optional watchdog in the core (controls back to 0 after N ms without
      a frame, with a keep-alive from the backend) was discussed and not
      built. Until then the docs tell the user to keep limits in the design.
- [ ] A write during a stream waits for the burst in flight (the core only
      takes `CMD_ABORT` then). Fine for small bursts; with 10000-sample
      bursts a button is slow.

Not GUI only, so not part of this batch:

- [ ] Trigger on a level (value above/below a threshold). The core only
      triggers on one selected bit of a channel (level or edge), so this
      needs a comparator in `scope_trigger` and a `CMD_SET_TRIGGER` payload
      change (doc, `scope_defs.vh`, `scope_cmd_if.v`, `protocol.py`,
      `sim_device.py`, `scope_tb.v`, then the board).

## 16-bit channels (implemented 2026-10-14)

Asked for by the user: channels of 16 bits shown as one value without
splitting them over two channels. (The other half of the question, controls
that send 16 bits, needed nothing: controls were already 32 bits.)

- [x] RTL: `p_channel_max_width` on `scope_top`, lanes sized from it in
      `scope_top` and `scope_trigger`; `bit_select` uses bit 3 of the
      trigger byte (reserved until now), a value past the lane never
      triggers; the dump/stream byte counters start from a 4-bit
      `lp_last_byte_idx` (with 16-byte samples `p_frame_bytes[3:0]` was 0
      and only came out right by wrapping). No protocol version change:
      `GET_INFO` already had a byte per channel width, and an older host
      never sets bit 3.
- [x] `protocol.py`, `app.py`, `sim_device.py`, `scope_math.js`:
      `bit_select` / `trigger.channels.N.bit` 0-15.
- [x] Simulation: `scope_tb.v` unchanged and passing (the default build);
      `scope_wide_tb.v` (8 channels, seven of 16 bits and one of 12,
      16-byte samples): GET_INFO, trigger on bit 12, dump and stream byte
      order and zero padding. The trigger test was seen to fail with
      `bit_select` cut back to 3 bits. `test_protocol` decodes 16-bit
      channels.
- [ ] `sim_device.py` has no 16-bit channel, so the GUI has not been
      exercised with one (the page has no 8-bit limit of its own: widths
      come from GET_INFO, and the trigger bit list follows the width).
- [ ] On the board: a build with `p_channel_max_width(16)`.

## Still to do

- [ ] Use it on real signals: replace the example in the Drone FPGA_SOM
      design with a `scope_top` fed by the IMU SPI lines and valid flag.
- [x] The copy of the RTL in the Drone project has the controls (checked
      2026-10-12: `scope_top.v` there has the `o_controlN` ports).
- [ ] GUI stream view: consecutive bursts are not contiguous in time (the
      host needs a moment between `CMD_STREAM_START`s), so slow signals show
      a small jump at every burst boundary. Larger bursts make it rarer.
- [ ] Try other configurations: a faster baud rate, a 100 MHz clock, wide
      frames (8 channels x 8 bits), another USB-UART adapter.
- [ ] A committed testbench that drives the RTL with frames produced by
      `protocol.py` (today that cross-check was done once by hand).
