# fpga_scope UART Command Protocol

This document is the single source of truth for the host <-> FPGA wire protocol.
The RTL (`source/scope_cmd_if.v`) and the Python backend (`gui/backend/protocol.py`)
are both independent implementations of this spec — if you change one, change the
other and this document too.

The core reports its own configuration at runtime (`CMD_GET_INFO`), so the same
GUI/backend works against any project that instantiates `scope_top`, regardless of
how many channels/bits it was built with.

## Modes

`scope_top` has two operating modes, both always built in (there is no
build-time enable). `CMD_GET_INFO` still reports them in `modes_supported` so a
host never has to assume:

| Mode            | id  | Behaviour                                             |
|------------------|-----|--------------------------------------------------------|
| `MODE_SCOPE`     | 0   | ring-buffer capture + trigger, the classic oscilloscope |
| `MODE_STREAM`    | 1   | live sample streaming straight to the host in count-bounded bursts, no ring buffer, no trigger — for a live plotter / logic-probe view |

The active mode is selected at runtime with `CMD_SET_MODE` and only one mode is
active at a time; the core comes out of reset in `MODE_SCOPE`. Switching modes
is only accepted while idle. Both modes reuse the `decimation` field from the
last `CMD_SET_TRIGGER` as their sample-rate divider; the trigger/pre/post fields
are simply unused in `MODE_STREAM`.

## Physical layer

Plain async UART, 8N1. The baud rate is `clock frequency / p_uart_preescaler`
(see the [UART module](../../../modules/uart/uart.md)) — there is no autobaud,
the host must know the configured rate.

## Framing

All frames, both directions, share the same shape:

| Field   | Size | Notes                                            |
|---------|------|---------------------------------------------------|
| SYNC    | 1 B  | `0xAA` host→device, `0x55` device→host             |
| CMD     | 1 B  | opcode (device echoes the opcode it is replying to)|
| LEN_H   | 1 B  | payload length, big-endian high byte               |
| LEN_L   | 1 B  | payload length, big-endian low byte                |
| PAYLOAD | LEN B| opcode-specific                                    |
| CHK     | 1 B  | XOR of CMD, LEN_H, LEN_L and every payload byte     |

A 2-byte length field is used (instead of 1) because a capture dump can easily
exceed 255 bytes. Frames with a bad checksum are silently dropped by both ends.

The receiver is byte-synchronous: it scans for SYNC, then reads CMD/LEN/PAYLOAD/CHK.
If CHK fails it drops the partial frame and resumes scanning for SYNC — a single
corrupted byte can't permanently wedge the link.

## Opcodes

| Opcode | Name                | Mode           | Payload out                                     | Payload in (response)                             |
|--------|---------------------|----------------|---------------------------------------------------|-----------------------------------------------------|
| 0x01   | `CMD_GET_INFO`      | any            | none                                              | see [GET_INFO response](#get_info-response)          |
| 0x02   | `CMD_SET_TRIGGER`   | idle           | see [SET_TRIGGER payload](#set_trigger-payload-15-bytes)   | 1 B status (`0x00`=OK, `0x01`=error)                 |
| 0x03   | `CMD_ARM`           | scope          | none                                              | 1 B status                                           |
| 0x04   | `CMD_GET_STATUS`    | any            | none                                              | see [GET_STATUS response](#get_status-response)      |
| 0x05   | `CMD_DUMP`          | scope (done)   | none                                              | raw stream, see [CMD_DUMP](#cmd_dump)                |
| 0x06   | `CMD_ABORT`         | any            | none                                              | 1 B status; aborts a capture or stops a stream        |
| 0x07   | `CMD_SET_MODE`      | idle           | 1 B mode id (`0`=scope, `1`=stream)               | 1 B status                                            |
| 0x08   | `CMD_STREAM_START`  | stream (idle)  | 4 B sample_count, big-endian                      | 1 B status, then raw sample burst, see [streaming](#stream-mode) |
| 0x09   | `CMD_CONTROL_WRITE` | any            | 1 B control index, 4 B value, see [controls](#controls) | 1 B status                                       |
| 0x0A   | `CMD_CONTROL_READ`  | any            | 1 B control index                                 | 1 B control index, 4 B value                          |

### GET_INFO response

Lets the GUI auto-adapt to whatever project the core was built into.

| Field             | Size | Meaning                                                        |
|-------------------|------|-----------------------------------------------------------------|
| protocol_version  | 1 B  | currently `0x02`. `0x01`: a core without [controls](#controls), otherwise identical |
| modes_supported   | 1 B  | bitmask: bit0 = `MODE_SCOPE`, bit1 = `MODE_STREAM` (currently always `0x03`) |
| num_channels      | 1 B  | number of configured channels (1-8)                              |
| channel_widths[8] | 8 B  | width in bits (1-16) of each channel lane; `0` = lane unused. Above 8 only in a core built with `p_channel_max_width` > 8 |
| buffer_depth_log2 | 1 B  | ring buffer depth is `2^buffer_depth_log2` samples |
| frame_bytes       | 1 B  | bytes per sample = `ceil(sum(channel_widths) / 8)`                |
| clk_freq_hz        | 4 B  | sample clock frequency, big-endian, for the GUI's time axis      |

### SET_TRIGGER payload (15 bytes)

| Field                | Size | Meaning                                                                |
|----------------------|------|--------------------------------------------------------------------------|
| channel_cfg[8]       | 8 B  | one byte per channel lane, see bit layout below                          |
| combine_mode         | 1 B  | `0`=AND all enabled channel conditions, `1`=OR them                      |
| pre_trigger_count    | 2 B  | samples to keep before the trigger event, big-endian                    |
| post_trigger_count   | 2 B  | samples to capture after the trigger event, big-endian                   |
| decimation           | 2 B  | sample every N clock cycles, big-endian, `0` and `1` both mean "every cycle" |

`channel_cfg[i]` bit layout (one byte per channel, unused channels are ignored):

```
bit 7    : enable        (1 = this channel participates in the trigger condition)
bit 6    : reserved (0)
bits 5:4 : type           00 = level, trigger source bit == 0
                            01 = level, trigger source bit == 1
                            10 = edge, rising  (0 -> 1)
                            11 = edge, falling (1 -> 0)
bits 3:0 : bit_select      which bit of the channel's own width is used as the
                            trigger source (0 = LSB); must be < that channel's width.
                            Bit 3 is only ever set for a channel wider than 8 bits;
                            a value past the core's lane width never triggers
```

`pre_trigger_count + post_trigger_count` must be <= `2^buffer_depth_log2`; the core
clamps rather than rejecting if it isn't (see `scope_ctrl.v`).

After `CMD_ARM` the core ignores trigger events until `pre_trigger_count` samples
have been written, so the dumped window never contains samples from before the
arm.

### GET_STATUS response

The meaning of `state` depends on the currently-selected mode (`CMD_SET_MODE`):

| Field       | Size | Meaning                                                                          |
|-------------|------|--------------------------------------------------------------------------------------|
| state       | 1 B  | `MODE_SCOPE`: `0`=idle,`1`=armed,`2`=capturing,`3`=done. `MODE_STREAM`: `0`=idle,`1`=running |
| fill_count  | 2 B  | `MODE_SCOPE`: samples written since arming, saturates at `pre_trigger_count + post_trigger_count`. `MODE_STREAM`: samples remaining in the current burst (counts down to 0). Big-endian either way. |

### CMD_DUMP

Once `state == done`, `CMD_DUMP` streams the captured window oldest-sample-first,
`frame_bytes` bytes per sample, MSB of the sample first, for
`pre_trigger_count + post_trigger_count` samples (the values latched at the last
`CMD_ARM`, clamped to `2^buffer_depth_log2`) — no per-sample framing, it's one
continuous payload inside the normal SYNC/CMD/LEN/PAYLOAD/CHK envelope. Within a
sample, channel 0 occupies the least-significant bits of the frame, and each
channel's own bits are right-justified within its slice (a 3-bit channel uses
the low 3 bits of its slice). There is no real-time deadline on this transfer;
the host reads at whatever rate the UART delivers.

A dump does **not** return the core to `idle`: it stays in `done` (so the same
capture can be dumped again) until `CMD_ABORT` is sent. `CMD_ARM`,
`CMD_SET_TRIGGER` and `CMD_SET_MODE` are all rejected until then.

Because `LEN` is a 16-bit field, `(pre_trigger_count + post_trigger_count) * frame_bytes`
must not exceed 65535. For wide frames pick `buffer_depth_log2` accordingly
(e.g. an 8-channel, 8-bit-each build has `frame_bytes = 8`, capping the usable
buffer at 8191 samples; 8 channels of 16 bits have `frame_bytes = 16` and 4095).

### Stream mode

Streaming is **count-bounded**, not open-ended — the host always says how many
samples it wants, and the device sends exactly that many, then stops on its own.
This sidesteps a real ambiguity: raw sample bytes can legitimately be any value,
including `0x55`, so there is no way for the host to reliably tell "still raw
samples" apart from "a new framed response starting" by inspecting the bytes. A
known, host-chosen count removes the ambiguity entirely — the host just reads
`sample_count * frame_bytes` bytes and it's done.

`CMD_STREAM_START` (only valid in `MODE_STREAM`, from idle) payload:

| Field        | Size | Meaning                                    |
|--------------|------|----------------------------------------------|
| sample_count | 4 B  | how many samples to stream, big-endian        |

The device replies with a normal 1-byte status frame, then writes
`sample_count` raw `frame_bytes`-sized sample words back-to-back with **no
per-sample framing and no outer SYNC/LEN/CHK envelope** (same packed layout as
`CMD_DUMP`), one sample every `decimation` sample-clock cycles. After the last
sample word the core returns to idle by itself — no closing frame, the host
already knows it has everything once it has read `sample_count * frame_bytes`
bytes.

For a live/continuous view, the GUI just issues `CMD_STREAM_START` again for the
next batch as soon as the previous one finishes (e.g. a few hundred samples at a
time) — this is the same approach most low-cost USB logic analyzers use, and it
keeps the wire protocol simple and race-free instead of needing an asynchronous
stop.

To abandon a burst early, send `CMD_ABORT`. Because raw sample bytes can't be
told apart from a response frame by content alone, the host must fall back to
the generic resync behaviour from the [Framing](#framing) section (scan for
`0x55`, verify CHK, drop and rescan on mismatch) to find `CMD_ABORT`'s status
frame — rare in practice, since the normal path is simply requesting small
enough batches that you let them finish.

### Controls

Eight 32-bit registers that the host writes and the FPGA design reads, on
`scope_top`'s `o_control0` ... `o_control7` outputs. They have nothing to do
with capturing: they let the host press a button, flip a switch or set a value
in the design under test. Every core has all eight (there is no parameter), and
all are `0` after reset. What each one means is up to the design; the core only
stores them.

`CMD_CONTROL_WRITE` payload (5 bytes):

| Field | Size | Meaning                                  |
|-------|------|-------------------------------------------|
| index | 1 B  | which control, `0`-`7`                     |
| value | 4 B  | the new value, big-endian                  |

The core answers `0x00`, or `0x01` and changes nothing if `index` is above 7 or
the payload is not exactly 5 bytes. On an accepted write:

- all 32 bits of `o_controlN` change in the same clock cycle, and only after the
  frame's checksum has been verified, so the design never sees part of a value;
- `o_control_update[N]` is high for that one cycle. It pulses on **every**
  accepted write, also when the value written is the one the control already
  held: that is what makes a control usable as a push button.

`CMD_CONTROL_READ` (payload: 1 B index) returns the index and the value the
control holds, 5 bytes. An index above 7 gets no response.

Both commands are accepted in either mode and in any capture state (idle,
armed, capturing, done): a control can be written while a capture waits for its
trigger. `CMD_ABORT` does not change the controls; only reset clears them.

A core with `protocol_version` `0x01` has no controls and ignores both opcodes
(no response), so a host must check the version in `CMD_GET_INFO` before using
them.

The controls keep their value for as long as the FPGA is not reset, whatever
happens to the host: there is no timeout. A design that drives something real
from a control must not rely on the host to bring it back to a safe value.

## Status codes

| Code | Meaning                                              |
|------|--------------------------------------------------------|
| 0x00 | OK                                                      |
| 0x01 | rejected (e.g. `CMD_SET_TRIGGER`/`CMD_SET_MODE`/`CMD_ARM` while not idle, or a `CMD_CONTROL_WRITE` with a bad index or length) |

A command that is structurally invalid for the current state — most notably
`CMD_DUMP` sent while not in `done`, or `CMD_STREAM_START` while not idle — gets
no response at all, the same way a bad checksum does. The host should always
poll `CMD_GET_STATUS` before `CMD_DUMP`/`CMD_STREAM_START` rather than racing them.

While a `CMD_DUMP` transfer or a stream burst is in flight the core processes
only `CMD_ABORT`; any other command sent in that window is dropped without a
response. That includes `CMD_CONTROL_WRITE`: the host must send it between two
bursts, not during one.
