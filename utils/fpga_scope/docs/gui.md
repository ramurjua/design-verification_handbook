# fpga_scope — Using the GUI

How to read values off the plot, set up each channel (signed, gain, offset, name), zoom, measure, write values to the FPGA with buttons, and keep the setup in a file.

🧪 Status: everything on this page is checked by tests that drive the real page in a headless browser against the simulated device (`gui/backend/test_frontend.py`). The display features were also used on a board, by hand (2026-10-12); recording a stream has only run against the simulated device. Named values, bit fields and drop-down controls (2026-10-25) are verified by the tests and were checked by hand against the simulated `sim-fsm` port; being GUI only, they need no board test. For the controls, the user tried the buttons from the GUI on the board (2026-10-12) and they worked; what exactly was checked was not written down. Apart from the controls, nothing here changes what is sent to the FPGA.

## The plot

Each signal has a lane with its own Y axis. Under the plot there is a table with the minimum, maximum, mean and peak-to-peak value of every signal over the samples that are visible. A signal with [named values](#named-values-and-bit-fields) shows `—` there instead, since a state has no mean.

| Action | Mouse | Keyboard (click the plot first) |
|--------|-------|---------------------------------|
| Read the values at a sample | Move over the plot | Left / right arrow |
| Zoom in and out in time | Wheel, or **Zoom in** / **Zoom out** | `+` / `-` |
| Move along a zoomed capture | Drag | Left / right arrow past the edge |
| Show everything again | Double click, or **Reset zoom** | `0` |
| Place cursor A | Click | `A` |
| Place cursor B | Shift + click | `B` |
| Move a cursor | Drag it | |

With both cursors placed, the line above the table gives the time between them and its inverse (a frequency), and the table gives each signal's value at A, at B, and the difference.

Zoom works on a finished capture and on a stream once it is stopped. A running stream always shows its whole window.

## Channel settings

The **Channels** list has one block per channel. The checkbox shows or hides it; click the name to open its settings.

| Setting | What it does |
|---------|--------------|
| Name, Unit | Shown in the lane, the readouts and the CSV instead of `ch3` |
| Signed (two's complement) | The top bit is the sign: an 8-bit `0xFF` is shown as -1 instead of 255 |
| Fraction bits | For fixed point: with 4, the value is divided by 16 |
| Gain, Offset | Shown value = value × gain + offset, to read it in real units |
| Raw value as | How the raw number is written next to the scaled one: hex, decimal or binary |
| Y range | Full scale of the signal, fitted to the visible samples, or manual limits |
| Trace | Steps (as sampled), straight lines between samples, or a bus: a band with the value written inside, for a state or a counter |
| Lane height | How much of the plot the lane takes |
| One lane per bit | Adds a lane for every bit of the signal under it |
| Upper bits from | Joins another channel on top of this one, for a value wider than one channel |
| Draw in the lane of | Puts this signal in another signal's lane, on that lane's Y axis |

The shown value is computed in this order: combine the channels, apply the sign, divide by 2^fraction bits, multiply by the gain, add the offset.

**A value wider than a channel.** A channel carries 8 bits unless the core is built with `p_channel_max_width(16)` (see [the integration guide](integration.md)), so with the default build a 16-bit value arrives on two channels, for example `i_ch2(gyro[7:0])` and `i_ch3(gyro[15:8])`. In the settings of `ch2`, set **Upper bits from** to `ch3`: the two become one 16-bit signal that takes its settings (including Signed) from `ch2`, and `ch3` no longer has a trace of its own. Channels can be chained up to 32 bits.

The trigger is not affected by any of this: it still acts on one bit of one channel.

### Named values and bit fields

A state machine reads better by its state names than by numbers. These are set only in the [configuration file](#writing-a-configuration-by-hand) (the channel settings show what a channel has, with a note "Set in the configuration file"), and they are kept when the GUI saves the configuration.

- **`values` on a channel** names the raw values of the whole signal: `"3": { "name": "baro", "style": "bus", "values": { "0": "IDLE", "1": "RESET", "2": "READ" } }`.
- **`fields` on a channel** splits it into bit fields, each with its own name and names of values, for a channel that packs several state machines. A channel with fields is drawn as one bus lane per field, called `<channel>.<field>` (for example `state.card`), in place of its own lane. Hiding the channel hides its fields, and *Lane height* applies to each of them.

```json
"6": { "name": "state", "fields": [
  { "name": "card", "bits": [7, 4], "values": { "0": "IDLE", "1": "RAMP", "2": "RUN", "3": "BRAKE", "4": "FAULT" } },
  { "name": "fsm",  "bits": [3, 0], "values": { "0": "START_UP", "1": "MOTOR_AWAKE", "2": "READY", "8": "FAULT_IMU_ID" } }
] }
```

How they work:

- A key is the **raw, unsigned value** of the bits, as it comes from the FPGA, in decimal (`"10"`) or hex (`"0xA"`). *Signed*, *Fraction bits*, *Gain* and *Offset* do not apply to names: a 4-bit `0xF` is `"15"`, also on a signed channel.
- `bits` is `[msb, lsb]` as in Verilog, or a single number for one bit. Bits count on the signal as shown, so on a signal joined with *Upper bits from* they go up to 31. Bits above the signal's width read as 0, and the channel settings say so.
- A value without a name is shown as the number, written as *Raw value as* says (`0x6`). A field without `values` shows its number.
- Where the names show: inside the bus band (with *Trace* set to bus; fields are always a bus), in the hover readout and the A / B columns as `RUN (0x2)`, and in the CSV. The statistics show `—` for a signal or field with names, also for B − A. A field without names keeps its statistics.
- To see it without a board, connect to the port `sim-fsm` (a simulated device with state machines on its channels and a motor speed that control 0 changes) and open `gui/examples/sim-fsm.json` with **Open file...**: it has whole-channel names, two fields with names, a value without a name, and a drop-down list.
- The trigger still acts on one bit: there is no trigger on a name or on "field == value", which would need a comparator in the FPGA. A field of one bit can be triggered on through that bit of its channel.

## Controls: writing to the FPGA

The scope core has eight outputs the design can read, `o_control0` to `o_control7` (see the [integration guide](integration.md), step 5). They have their own panel, to the right of the plot, apart from everything that has to do with capturing and displaying: the controls in use at the top, and under **Set up** what each of the eight is in this project. A control that is *Not used* only appears in that list, and a project with no controls leaves all eight that way.

| Shown as | In the panel | What it writes |
|----------|----------------|----------------|
| Not used | nothing | nothing |
| Button | a button with the control's name | *Value a press writes* (1 unless changed), on every press. The FPGA gets a one-clock pulse each time |
| Switch (on / off) | a button that stays pressed while on | 1 when switched on, 0 when switched off |
| Value | a number field, a **Send** button and the value the FPGA holds now | the number typed, converted to its raw value |
| Drop-down list | a list of named entries, showing the one the FPGA holds now | the value of the entry picked, as soon as it is picked |

A *Value* is typed in real units, with the same settings as a channel, applied the other way round: raw value = (typed − offset) ÷ gain × 2^fraction bits, rounded. With gain 0.5 and unit `rpm`, typing 1200 writes 2400. *Signed* allows negative numbers, sent in two's complement. *Smallest allowed* and *Largest allowed* refuse anything outside them before it is sent: use them for anything that should not get a typing mistake.

A *Drop-down list* is for picking one of a few fixed values, such as which motor to look at: each entry is a value and its name. In the settings, *Entries* takes them as `value=name` pairs separated by `;`, for example `0=MOTOR 0; 1=MOTOR 1; 2=MOTOR 2`, with the value a whole number (decimal or `0x...`); a list that does not read that way yet is not applied. In a configuration file they are `"values"`, keyed by the value as for a [channel](#named-values-and-bit-fields): `"3": { "name": "motor", "kind": "select", "values": { "0": "MOTOR 0", "1": "MOTOR 1" } }`. Picking an entry writes its value as it is (no scaling, no limits), with no **Send**. The list shows what the FPGA holds, read back like a switch: `?` while that is not known, and for example `7 (not in the list)` when it holds a value with no entry.

Good to know:

- After every write the GUI reads the control back and shows what the FPGA holds, so the switch position and the "now" value come from the board, not from what was clicked. They are read again on every connect: the FPGA keeps its values when the GUI is closed.
- Controls work on both tabs and while a capture is waiting for its trigger. During a stream a write waits for the burst in flight, so with many samples per burst it is not immediate.
- With a bitstream built before the controls existed, they are shown greyed out with a note, and everything else works as before.
- Loading a configuration never writes anything to the FPGA. It only changes names, kinds and scaling.

## Saving the setup

The channel settings, the controls, the trigger and the window are one configuration. The browser remembers the current one by itself, so it is still there the next time the page is opened. To keep several, or move them between computers, use the **Configuration** block:

- **Save / Load / Delete** work on a name. The backend keeps each one as `<name>.json` in `gui/configs/` (another folder: `python app.py --config-dir <folder>`). A name is letters, digits, `-` and `_`.
- **Open file...** opens the file dialog and loads any JSON file from the computer.
- **Save as file...** downloads the current configuration as a JSON file.

### Writing a configuration by hand

A file only needs the settings it changes; everything else takes its default. Channels can be given by number. This is a complete, valid file:

```json
{
  "channels": {
    "0": { "name": "spi_clk" },
    "1": { "name": "spi_cs_n" },
    "2": { "name": "gyro_x", "unit": "dps", "signed": true, "gain": 0.0625, "high": 3, "range": "auto" },
    "4": { "name": "state", "style": "bus", "format": "bin", "values": { "0": "IDLE", "1": "BUSY", "0x2": "DONE" } }
  },
  "controls": {
    "0": { "name": "run", "kind": "button" },
    "1": { "name": "enable", "kind": "toggle" },
    "2": { "name": "speed", "kind": "value", "unit": "rpm", "gain": 0.5, "min": 0, "max": 3000 }
  },
  "trigger": { "channels": { "1": { "type": "fall" }, "0": { "type": "off" } }, "combine": "and" },
  "window": { "pre": 100, "post": 900, "decimation": 4 }
}
```

After loading, the GUI lists any setting it could not use (a misspelt name, a text where a number is expected) and leaves that one at its default.

| Key | Values | Default |
|-----|--------|---------|
| `channels.N.name` | text, up to 24 characters | `"chN"` |
| `channels.N.unit` | text, up to 12 characters | `""` |
| `channels.N.visible` | `true` / `false` | `true` |
| `channels.N.signed` | `true` / `false` | `false` |
| `channels.N.frac` | fraction bits, 0 to 32 | `0` |
| `channels.N.gain`, `offset` | numbers | `1`, `0` |
| `channels.N.format` | `"hex"`, `"dec"`, `"bin"` | `"hex"` |
| `channels.N.range` | `"full"`, `"auto"`, `"manual"` | `"full"` |
| `channels.N.min`, `max` | Y limits, used when `range` is `"manual"` | `0`, `255` |
| `channels.N.style` | `"step"`, `"line"`, `"bus"` | `"step"` |
| `channels.N.height` | `"auto"`, `"small"`, `"medium"`, `"large"`, `"xlarge"` | `"auto"` |
| `channels.N.bits` | `true` for one lane per bit | `false` |
| `channels.N.high` | number of the channel with the upper bits, or `null` | `null` |
| `channels.N.lane` | number of the channel whose lane to share, or `null` | `null` |
| `channels.N.values` | names of raw values: `{ "0": "IDLE", "0x1": "RUN" }`, keys the unsigned raw value in decimal or `0x` hex, names up to 24 characters. See [Named values and bit fields](#named-values-and-bit-fields) | `{}` |
| `channels.N.fields` | list of up to 8 bit fields, drawn in place of the channel | `[]` |
| `channels.N.fields[i].name` | text, up to 24 characters | `"f<i>"` |
| `channels.N.fields[i].bits` | `[msb, lsb]`, or one number for a single bit, 0 to 31. Required: a field without it is not drawn | — |
| `channels.N.fields[i].values` | names of the field's raw values, as `channels.N.values` | `{}` |
| `controls.N.name` | text, up to 24 characters | `"controlN"` |
| `controls.N.kind` | `"off"`, `"button"`, `"toggle"`, `"value"`, `"select"` (drop-down list) | `"off"` |
| `controls.N.value` | button: the raw value a press writes, 0 to 4294967295 | `1` |
| `controls.N.unit` | value: text, up to 12 characters | `""` |
| `controls.N.signed` | value: `true` to allow negative numbers | `false` |
| `controls.N.frac` | value: fraction bits, 0 to 32 | `0` |
| `controls.N.gain`, `offset` | value: numbers, gain not 0 | `1`, `0` |
| `controls.N.min`, `max` | value: limits on what can be sent, or `null` for none | `null` |
| `controls.N.values` | select: the entries, `{ "0": "MOTOR 0", "1": "MOTOR 1" }`, keys the raw value written (decimal or `0x` hex, 0 to 4294967295), names up to 24 characters | `{}` |
| `trigger.channels.N.type` | `"off"`, `"rise"`, `"fall"`, `"high"`, `"low"` | `"rise"` on channel 0, `"off"` on the rest |
| `trigger.channels.N.bit` | bit of the channel to trigger on, 0 to 15 (below that channel's width) | `0` |
| `trigger.combine` | `"and"`, `"or"` | `"and"` |
| `window.pre`, `post` | samples before and after the trigger. Together at most the "captures up to N samples" shown after connecting, which is one less than the buffer; with `post` 0, `pre` at most N - 1. The hint under the window says when it is too long | `100`, `300` |
| `window.decimation` | sample every N clocks, 1 to 65535 | `1` |
| `stream.decimation`, `batch`, `window` | the three Stream settings | `1`, `200`, `2000` |

`N` is the channel or control number, 0 to 7. `"channels"` and `"controls"` can also be lists in order, which is what the GUI writes.

## Captures

- **Download CSV** writes every signal as shown (scaled, under its name), hidden ones included. A signal with named values gets a column `<name>:name` right after its own, empty where a value has no name. A channel with bit fields keeps its column, with the packed raw value, followed by a column per field with the field's raw value (`state.card`) and, if the field has names, `state.card:name`. On the Stream tab that is only the samples on screen; for the whole stream, see below.
- **Save capture** writes a JSON file with the raw samples and the configuration. **Load capture** opens one again, also without a board connected.
- **Set as reference** keeps the capture on screen, faded, behind the following ones, lined up on the trigger. **Clear reference** removes it.

## Recording a stream

The Stream plot only keeps the last *Samples on screen*; older samples are dropped. To keep all of them, use the **Recording** buttons on the Stream tab:

- **Start recording** keeps every burst that arrives from then on. It can be clicked before **Start**, so that the recording holds the stream from its first sample, and it carries on if the stream is stopped and started again.
- **Stop recording** ends it and downloads `fpga_scope_recording.csv`. Nothing is written before that, and the recording is lost if the page is closed or reloaded first.

The file has one row per sample: its number, the burst it arrived in, and every signal as shown (scaled, under its name, with the same name and field columns), like **Download CSV**. Every sample the FPGA sent is in the file, in order, but the stream itself is not continuous:

- Inside a burst the samples are evenly spaced, not one per clock. The core takes a new sample only when the UART can send it, so the spacing is the longer of *Sample every N clocks* and the time one sample takes on the UART (about 87 µs per byte of frame at 115200 baud). Anything faster than that goes unseen.
- Between two bursts the core is not sampling, so there is a longer gap of unknown length wherever the `burst` column changes. More *Samples per burst* makes these rarer.

The recording is held in the browser's memory until it is stopped, so it suits minutes of data rather than days.

## Tests

```bash
cd utils/fpga_scope/gui/backend
python -m unittest test_frontend
```

This opens two pages of `gui/frontend/tests/` in a headless Chrome or Edge: `unit.html` checks the display maths in `scope_math.js`, and `e2e.html` drives the real page against the simulated device. With the backend running, the same pages can be opened by hand, for example http://127.0.0.1:8000/tests/unit.html. `e2e.html` connects to `sim`, captures and streams, so do not open it while a board is in use.
