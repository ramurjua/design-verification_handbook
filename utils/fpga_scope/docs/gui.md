# fpga_scope — Using the GUI

How to read values off the plot, set up each channel (signed, gain, offset, name), zoom, measure, and keep the setup in a file.

🧪 Status: everything on this page is checked by tests that drive the real page in a headless browser against the simulated device (`gui/backend/test_frontend.py`). It has not been tried on a board yet; nothing here changes what is sent to the FPGA.

## The plot

Each signal has a lane with its own Y axis. Under the plot there is a table with the minimum, maximum, mean and peak-to-peak value of every signal over the samples that are visible.

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
| Upper bits from | Joins another channel on top of this one, for a value wider than 8 bits |
| Draw in the lane of | Puts this signal in another signal's lane, on that lane's Y axis |

The shown value is computed in this order: combine the channels, apply the sign, divide by 2^fraction bits, multiply by the gain, add the offset.

**A 16-bit value.** A channel carries 8 bits at most, so a 16-bit value arrives on two channels, for example `i_ch2(gyro[7:0])` and `i_ch3(gyro[15:8])`. In the settings of `ch2`, set **Upper bits from** to `ch3`: the two become one 16-bit signal that takes its settings (including Signed) from `ch2`, and `ch3` no longer has a trace of its own. Channels can be chained up to 32 bits.

The trigger is not affected by any of this: it still acts on one bit of one channel.

## Saving the setup

The channel settings, the trigger and the window are one configuration. The browser remembers the current one by itself, so it is still there the next time the page is opened. To keep several, or move them between computers, use the **Configuration** block:

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
    "4": { "name": "state", "style": "bus", "format": "bin" }
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
| `trigger.channels.N.type` | `"off"`, `"rise"`, `"fall"`, `"high"`, `"low"` | `"rise"` on channel 0, `"off"` on the rest |
| `trigger.channels.N.bit` | bit of the channel to trigger on, 0 to 7 | `0` |
| `trigger.combine` | `"and"`, `"or"` | `"and"` |
| `window.pre`, `post` | samples before and after the trigger | `100`, `300` |
| `window.decimation` | sample every N clocks, 1 to 65535 | `1` |
| `stream.decimation`, `batch`, `window` | the three Stream settings | `1`, `200`, `2000` |

`N` is the channel number, 0 to 7. `"channels"` can also be a list in channel order, which is what the GUI writes.

## Captures

- **Download CSV** writes every signal as shown (scaled, under its name), hidden ones included.
- **Save capture** writes a JSON file with the raw samples and the configuration. **Load capture** opens one again, also without a board connected.
- **Set as reference** keeps the capture on screen, faded, behind the following ones, lined up on the trigger. **Clear reference** removes it.

## Tests

```bash
cd utils/fpga_scope/gui/backend
python -m unittest test_frontend
```

This opens two pages of `gui/frontend/tests/` in a headless Chrome or Edge: `unit.html` checks the display maths in `scope_math.js`, and `e2e.html` drives the real page against the simulated device. With the backend running, the same pages can be opened by hand, for example http://127.0.0.1:8000/tests/unit.html. `e2e.html` connects to `sim`, captures and streams, so do not open it while a board is in use.
