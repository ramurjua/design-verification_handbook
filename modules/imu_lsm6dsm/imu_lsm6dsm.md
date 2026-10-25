### 🔹 LSM6DSM IMU SPI driver

Driver for the ST LSM6DSM 6-axis IMU (3-axis accelerometer and 3-axis gyroscope) over SPI. It resets and identifies the chip, configures it, and then reads one accelerometer and gyroscope sample per `i_tick`, as six signed 16-bit values. The registers it uses are the same on the LSM6DSL and the LSM6DSO; only `WHO_AM_I` differs (`p_who_am_i`).

✔️ Verified via testbench against a behavioural model of the chip's SPI port that flags any edge that is not SPI mode 3: register writes in order, `WHO_AM_I` retries, burst samples, an absent chip, tick timing and overrun.

🧪 Status: Tested on real hardware with an LSM6DSM on a Spartan-7 (xc7s50) board, 25 MHz clock, ticks at 208 Hz (2026-10-12 and 2026-10-15): it identifies and configures the chip after a cold start, then all six axes read correctly (see [Verification](#verification)). `p_i2c_disable = 1` tested on the same board with an LPS22HB barometer on the bus (2026-10-16). Not yet checked on hardware: the gyroscope scale against a known rotation, and `WHO_AM_I` over many cold starts.

🏷️ Version: v1.1.0 (2026-10-25), see the [changelog](#changelog).

📁 [Source Code](source/imu_lsm6dsm.v)

📁 [Testbench](test/imu_lsm6dsm_tb.sv)

Depends on `spi_master.v` from the [SPI module](../spi/spi.md), instantiated internally; it needs the version with `p_cpha`.

📌 Instantiation:

```verilog
imu_lsm6dsm # (
    .p_spi_prescaler(),        /* spi_master prescaler: SCLK = clk / (2*(p_spi_prescaler/2+2)), at most 10 MHz */
    .p_reset_wait_cycles(),    /* clk cycles to wait after SW_RESET */
    .p_who_am_i(),             /* expected WHO_AM_I: 8'h6A LSM6DSM/LSM6DSL, 8'h6C LSM6DSO */
    .p_id_retry_wait_cycles(), /* clk cycles before reading WHO_AM_I again after a wrong answer */
    .p_id_max_attempts(),      /* WHO_AM_I reads before giving up (1-15), 0 = never give up */
    .p_odr_xl(),               /* CTRL1_XL.ODR_XL[3:0], accelerometer data rate */
    .p_fs_xl(),                /* CTRL1_XL.FS_XL[1:0], accelerometer full scale */
    .p_odr_g(),                /* CTRL2_G.ODR_G[3:0], gyroscope data rate */
    .p_fs_g(),                 /* CTRL2_G.FS_G[1:0], gyroscope full scale */
    .p_i2c_disable()           /* 1: also turn the chip's I2C off, for a shared SPI bus */
) imu_lsm6dsm (
    .clk(),
    .rst(),            /* Synchronous reset, active high */
    .i_tick(),         /* One-clock pulse: the driver may start its next SPI transaction */
    .o_spi_cs_n(),
    .o_spi_sck(),
    .o_spi_mosi(),
    .i_spi_miso(),
    .os16_gyro_x(),    /* Raw signed 16-bit values, updated together */
    .os16_gyro_y(),
    .os16_gyro_z(),
    .os16_accel_x(),
    .os16_accel_y(),
    .os16_accel_z(),
    .or_valid(),       /* One-clock pulse: a new sample is on the six outputs */
    .or_id_ok(),       /* Sticky: WHO_AM_I matched */
    .or_id_error(),    /* Sticky: WHO_AM_I never matched, the driver stopped */
    .or_overrun(),     /* Sticky: a tick arrived during a transaction */
    .o5_debug_state()  /* FSM state, for debug only */
);
```

## What the sensor measures

The LSM6DSM is a 6-axis IMU: a 3-axis accelerometer and a 3-axis gyroscope in one package (it also has a temperature sensor, not used by this driver). Each axis output is a 16-bit two's-complement value in raw LSB units:

- Accelerometer X/Y/Z — linear acceleration, scaled by the configured full-scale range.
- Gyroscope X/Y/Z — angular rate, scaled by the configured full-scale range.

Converting raw LSBs to physical units (g / dps) is left to whatever consumes this driver's outputs — it is not done in hardware here.

### Output units / scaling

Each axis output is a raw signed 16-bit LSB count, not a physical unit. Convert it by multiplying by the sensitivity for the *configured* full-scale range (datasheet, "Mechanical characteristics"):

| Accelerometer FS (`p_fs_xl`) | Sensitivity |
|---|---|
| ±2 g | 0.061 mg/LSB |
| ±4 g | 0.122 mg/LSB |
| ±8 g (driver default) | 0.244 mg/LSB |
| ±16 g | 0.488 mg/LSB |

| Gyroscope FS (`p_fs_g`) | Sensitivity |
|---|---|
| ±125 dps | 4.375 mdps/LSB |
| ±250 dps | 8.75 mdps/LSB |
| ±500 dps | 17.50 mdps/LSB |
| ±1000 dps (driver default) | 35 mdps/LSB |
| ±2000 dps | 70 mdps/LSB |

With the driver's default configuration:

```
accel_g   = os16_accel_x * 0.244 / 1000
gyro_dps  = os16_gyro_x  * 35    / 1000
```

If `p_fs_xl`/`p_fs_g` are changed, the consumer of these outputs must use the matching sensitivity from the tables above.

Checked on hardware: at rest and flat the accelerometer reads a total of 1.01 g, and the low byte of each axis carries noise of a few LSB (not stuck).

## SPI interface

The LSM6DSM is a SPI slave, 4-wire (CS, SCLK, MOSI/SDI, MISO/SDO), up to 10 MHz SCLK, in SPI mode 0 or 3. This driver uses **mode 3** (`spi_master` with `p_cpol = 1`, `p_cpha = 1`): SCLK is stopped high while CS is high, data changes on the falling edge and is captured on the rising edge.

`spi_master` must not be used with `p_cpol = 1` alone (`p_cpha = 0`) for this chip: that only inverts the clock, which gives mode 2 (MOSI changes on the rising edge the chip samples on), not mode 3. Seen on hardware: the `WHO_AM_I` command `0x8F` changed together with every rising edge and the IMU never answered.

With the default `p_spi_prescaler = 4`, one SPI bit takes 8 `clk` cycles (3.125 MHz SCLK at a 25 MHz `clk`). In general one bit takes `2 * (p_spi_prescaler/2 + 2)` clocks.

One transaction:

- Bit 0: R/W bit (`1` = read, `0` = write).
- Bits 1-7: 7-bit register address, MSB first.
- Bits 8-15 (and beyond, for multi-byte transfers): data byte(s), MSB first.

Multi-byte transfers append further 8-bit blocks at the same clock rate; the register address auto-increments between blocks when `CTRL3_C.IF_INC = 1` (the chip's own reset default).

The chip-select line is derived from `spi_master`'s busy status (`o_spi_cs_n` = not busy), so it frames each transaction automatically — the driver never toggles CS directly. The driver holds its own `spi_master`, so if other devices share SCK/MOSI/MISO, the integrator combines the pins outside this module and makes sure only one master transfers at a time (see `i_tick` below).

While its CS is high the chip is in I2C mode, and on a shared bus it would read the other devices' SPI traffic on SCK/MOSI as I2C. With `p_i2c_disable = 1` the driver writes `CTRL4_C.I2C_disable` (SPI only) during configuration; set it whenever another device shares the bus (for example the [LPS22HB barometer](../baro_lps22hb/baro_lps22hb.md)). The default `0` leaves I2C on, as in v1.0.0.

## Registers used by this driver

| Register | Address | Purpose |
|---|---|---|
| `WHO_AM_I` | `0x0F` (R) | Fixed at `0x6A` on the LSM6DSM. Used to confirm the SPI link is really talking to the expected part. |
| `CTRL1_XL` | `0x10` (R/W) | Accelerometer ODR + full-scale select. Layout: `ODR_XL[3:0] \| FS_XL[1:0] \| 0 \| 0` (the two low bits, filter bandwidth options, are written as 0). |
| `CTRL2_G` | `0x11` (R/W) | Gyroscope ODR + full-scale select. Layout: `ODR_G[3:0] \| FS_G[1:0] \| FS_125 \| 0`. |
| `CTRL3_C` | `0x12` (R/W) | Layout: `BOOT \| BDU \| H_LACTIVE \| PP_OD \| SIM \| IF_INC \| BLE \| SW_RESET`. |
| `CTRL4_C` | `0x13` (R/W) | Written only with `p_i2c_disable = 1`, as `0x04`: `I2C_disable = 1` (bit 2), every other bit at its default 0. |
| `OUTX_L_G` .. `OUTZ_H_XL` | `0x22`-`0x2D` (R) | 12 contiguous bytes: gyro X/Y/Z then accel X/Y/Z, low byte then high byte per axis. A single burst read starting at `0x22` grabs a full sample. |

### Available modes / options

**Accelerometer ODR (`CTRL1_XL.ODR_XL[3:0]`)**:

| Code | ODR |
|---|---|
| `0000` | Power-down |
| `0001` | 12.5 Hz |
| `0010` | 26 Hz |
| `0011` | 52 Hz |
| `0100` | 104 Hz |
| `0101` | 208 Hz |
| `0110` | 416 Hz |
| `0111` | 833 Hz |
| `1000` | 1.66 kHz |
| `1001` | 3.33 kHz |
| `1010` | 6.66 kHz |
| `1011` | 1.6 Hz (low-power only) |

**Accelerometer full scale (`CTRL1_XL.FS_XL[1:0]`)** (note the non-monotonic order):

| Code | Full scale |
|---|---|
| `00` | ±2 g |
| `01` | ±16 g |
| `10` | ±4 g |
| `11` | ±8 g |

**Gyroscope ODR (`CTRL2_G.ODR_G[3:0]`)** uses the same code table as the accelerometer above, from `0000` to `1010` (no 1.6 Hz).

**Gyroscope full scale (`CTRL2_G.FS_G[1:0]`)**, with `FS_125 = 0` (i.e. scale comes from these bits, not the fixed ±125 dps override):

| Code | Full scale |
|---|---|
| `00` | ±250 dps |
| `01` | ±500 dps |
| `10` | ±1000 dps |
| `11` | ±2000 dps |

**`CTRL3_C.BDU`** (block data update): `0` = output registers update continuously (an L/H byte pair can tear if read mid-update); `1` = an axis's L/H pair only updates as a unit, once both bytes have been read. This driver always sets `BDU = 1` so a burst read can't return a torn sample.

### Chosen configuration (driver defaults)

| Setting | Value | Reason |
|---|---|---|
| Accelerometer ODR | 208 Hz (`4'b0101`) | Comfortably fast for a drone attitude-control loop without over-driving the SPI bus. |
| Accelerometer FS | ±8 g (`2'b11`) | Headroom for aggressive drone maneuvers/vibration. |
| Gyroscope ODR | 208 Hz (`4'b0101`) | Matched to the accelerometer ODR so both axes come from roughly the same instant. |
| Gyroscope FS | ±1000 dps (`2'b10`) | Headroom for fast rotation rates while keeping reasonable resolution. |
| `BDU` | `1` | Glitch-free burst reads (see above). |
| `IF_INC` | `1` | Chip default; required for the burst read to walk `0x22..0x2D` in one transaction. |

All four ODR/FS settings are module parameters (`p_odr_xl`, `p_fs_xl`, `p_odr_g`, `p_fs_g`) — pass the raw register-field bit patterns from the tables above to reconfigure. The driver does not set the sample rate itself: it reads one sample per `i_tick`, so drive `i_tick` at the ODR chosen here.

## Driver behavior

On reset, the driver runs a fixed sequence over the internal `spi_master`, entirely via 16-bit single-register SPI transactions unless noted. **Every transaction, the power-up ones included, starts only on an `i_tick` pulse**, so the integrator decides exactly when the driver uses the bus. The waits below are minimum times: after each one the driver waits for the next tick. A tick that arrives while a transaction is still in progress is lost and latches `or_overrun`; ticks during the waits, or after the driver gave up, are ignored.

1. **Software reset** — write `CTRL3_C = 0x01` (`SW_RESET = 1`), then wait at least `p_reset_wait_cycles` clocks (default 1,000,000 = 40 ms at 25 MHz: the chip's turn-on time plus margin).
2. **ID check** — read `WHO_AM_I`. If it reads `p_who_am_i`, latch `or_id_ok` and continue to configuration. Otherwise wait at least `p_id_retry_wait_cycles` clocks (default 1 s at 25 MHz) and read it again, so an IMU that powers up later than the FPGA is still picked up. After `p_id_max_attempts` wrong readbacks in a row (default 10), latch `or_id_error` and stop (the driver never proceeds to configure or sample a device that didn't identify itself correctly).
3. **Configure** — write `CTRL3_C` (`BDU=1, IF_INC=1`), then, only with `p_i2c_disable = 1`, `CTRL4_C = 0x04` (I2C off), then `CTRL1_XL` (accel ODR/FS), then `CTRL2_G` (gyro ODR/FS).
4. **Steady state** — on every tick, issue one 13-byte SPI read (1 command byte + 12 data bytes) starting at `OUTX_L_G` (`0x22`). Once complete, split the 96 data bits into the 6 signed 16-bit axis outputs, pulse `or_valid` for one clock, and wait for the next tick.

### Driving `i_tick`

- **Rate**: in steady state one tick = one sample, so tick at the ODR (208 Hz by default: every 120192 clocks at 25 MHz). Power-up takes one tick per transaction plus the waits, so a few ticks after the waits end.
- **Spacing**: consecutive ticks must be further apart than the longest transaction, or a tick lands mid-transaction and `or_overrun` is set. The longest one is the burst read: it ends **834 clocks after its tick** at the default `p_spi_prescaler = 4` (measured in the testbench; 104 bits × 8 clocks plus 2 clocks of start). With another prescaler: `104 × 2 × (p_spi_prescaler/2 + 2) + 2`.
- **Shared bus**: when other SPI devices share SCK/MOSI/MISO, give each driver its own tick and keep at least that many clocks between this driver's tick and the next transaction of any other device.
- **Alone on the bus**, a plain divider is enough:

```verilog
reg [16:0] r_tick_count;
reg r_imu_tick;
always @(posedge clk) begin
  if (rst || r_tick_count == 17'd120191) r_tick_count <= 17'd0;
  else r_tick_count <= r_tick_count + 1'b1;
  r_imu_tick <= !rst && (r_tick_count == 17'd120191); /* 208 Hz at 25 MHz */
end
```

The sensor's own output rate comes from its internal oscillator, not from `clk`, so reading at exactly the nominal ODR occasionally returns the same sample twice or skips one.

## Module prototype

```verilog
module imu_lsm6dsm # (
  parameter p_spi_prescaler = 4,        // spi_master clock prescaler (see below)
  parameter p_reset_wait_cycles = 1000000,   // clk cycles to wait after SW_RESET
  parameter [7:0] p_who_am_i = 8'h6A,        // expected WHO_AM_I readback
  parameter p_id_retry_wait_cycles = 25000000, // clk cycles before re-reading WHO_AM_I
  parameter p_id_max_attempts = 10,          // WHO_AM_I reads before giving up
  parameter [3:0] p_odr_xl = 4'b0101,   // CTRL1_XL.ODR_XL[3:0]
  parameter [1:0] p_fs_xl  = 2'b11,     // CTRL1_XL.FS_XL[1:0]
  parameter [3:0] p_odr_g  = 4'b0101,   // CTRL2_G.ODR_G[3:0]
  parameter [1:0] p_fs_g   = 2'b10,     // CTRL2_G.FS_G[1:0]
  parameter p_i2c_disable  = 0          // 1: also write CTRL4_C.I2C_disable = 1
)(
  input clk,
  input rst,

  input i_tick,

  output o_spi_cs_n,
  output o_spi_sck,
  output o_spi_mosi,
  input  i_spi_miso,

  output reg signed [15:0] os16_gyro_x,
  output reg signed [15:0] os16_gyro_y,
  output reg signed [15:0] os16_gyro_z,
  output reg signed [15:0] os16_accel_x,
  output reg signed [15:0] os16_accel_y,
  output reg signed [15:0] os16_accel_z,
  output reg or_valid,
  output reg or_id_ok,
  output reg or_id_error,
  output reg or_overrun,
  output [4:0] o5_debug_state
);
```

### Parameters

| Name | Meaning |
|---|---|
| `p_spi_prescaler` | Prescaler passed straight through to the internal `spi_master` instance. One SPI bit takes `2 * (p_spi_prescaler/2 + 2)` clocks: SCLK = `clk / (2 * (p_spi_prescaler/2 + 2))`, which must stay at or below 10 MHz. Default 4: 3.125 MHz at 25 MHz. |
| `p_reset_wait_cycles` | Minimum number of `clk` cycles to hold off after issuing `SW_RESET` before checking `WHO_AM_I`, giving the chip time to reboot. |
| `p_who_am_i` | Expected `WHO_AM_I` readback. `0x6A` = LSM6DSM / LSM6DSL (default), `0x6C` = LSM6DSO; the registers this driver uses are the same on all three. |
| `p_id_retry_wait_cycles` | Minimum number of `clk` cycles to wait after a wrong `WHO_AM_I` readback before reading it again. |
| `p_id_max_attempts` | Total number of `WHO_AM_I` reads before the driver gives up and latches `or_id_error` (1 to 15). `0` = never give up: keep re-reading forever, `or_id_error` is never set. |
| `p_odr_xl` | Raw 4-bit value written to `CTRL1_XL.ODR_XL[3:0]` — accelerometer output data rate, see table above. |
| `p_fs_xl` | Raw 2-bit value written to `CTRL1_XL.FS_XL[1:0]` — accelerometer full scale, see table above. |
| `p_odr_g` | Raw 4-bit value written to `CTRL2_G.ODR_G[3:0]` — gyroscope output data rate, see table above. |
| `p_fs_g` | Raw 2-bit value written to `CTRL2_G.FS_G[1:0]` — gyroscope full scale, see table above. |
| `p_i2c_disable` | `1`: one more configuration write, `CTRL4_C = 0x04` (`I2C_disable`: SPI only), for a bus shared with other devices (see [SPI interface](#spi-interface)). `0` (default): no `CTRL4_C` write, the chip's I2C stays on. |

### Ports

| Name | Direction | Width | Meaning |
|---|---|---|---|
| `clk` | input | 1 | System clock driving both this module and the internal `spi_master`. |
| `rst` | input | 1 | Synchronous, active-high reset. |
| `i_tick` | input | 1 | One-clock pulse: the driver may start its next SPI transaction now. In steady state one tick = one sample. See "Driving `i_tick`" for the rate and the minimum spacing. |
| `o_spi_cs_n` | output | 1 | Active-low chip-select for the IMU. |
| `o_spi_sck` | output | 1 | SPI clock (mode 3: idles high). |
| `o_spi_mosi` | output | 1 | SPI data out to the IMU (SDI on the chip). Idles low. |
| `i_spi_miso` | input | 1 | SPI data in from the IMU (SDO on the chip). Released by the chip while CS is high: a pull-down on the pin gives it a defined level. |
| `os16_gyro_x` / `_y` / `_z` | output reg | 16, signed | Latest gyroscope reading per axis, raw LSBs, two's complement. |
| `os16_accel_x` / `_y` / `_z` | output reg | 16, signed | Latest accelerometer reading per axis, raw LSBs, two's complement. |
| `or_valid` | output reg | 1 | One-clock pulse: all six axis outputs above have just been updated with a new sample. |
| `or_id_ok` | output reg | 1 | Sticky: set if `WHO_AM_I` read back `p_who_am_i`. Stays `0` both before the check has run and if it fails — only means "checked and passed," not "hasn't failed yet." |
| `or_id_error` | output reg | 1 | Sticky: set once `WHO_AM_I` has failed to read back `p_who_am_i` on all `p_id_max_attempts` reads. Once set, the driver stops talking to the device. Stays `0` while retries are still in progress. |
| `or_overrun` | output reg | 1 | Sticky: a tick arrived while a transaction was still in progress, so it was lost (in steady state, a missed sample). Never set when the ticks respect the spacing in "Driving `i_tick`"; it flags a schedule that is too tight. |
| `o5_debug_state` | output | 5 | Current FSM state (the `st_*` values in the source), for debug only. `6` = stopped on ID error, `13` = waiting for the next sample tick, `15` = burst read in progress, `16` = sample latched, `17` = waiting to retry the ID check, `18`/`19` = `CTRL4_C` write (only with `p_i2c_disable = 1`). Once in the sample loop (`13`-`16`) bit 4 is set only in `16`, so there it doubles as a sample pulse. |

## Verification

`test/` (Icarus Verilog, `python run.py` from that folder) runs the driver against a behavioural model of the chip's SPI port in mode 3, which flags any edge that is not mode 3. `run.py` runs it twice, with `p_i2c_disable` 0 and 1 (logs in `sim_log` and `sim_log_i2c_disable`). It checks the register writes in order (with the `CTRL4_C` write only in the second run), two wrong `WHO_AM_I` answers followed by a right one, three burst samples, a second driver with no chip on the bus (gives up after 10 reads and goes quiet), that every transaction starts on a tick and ends 834 clocks after it at most, and that ticks closer than a transaction set `or_overrun`.

The testbench makes its ticks with a plain counter. In the project it comes from, the ticks come from a task scheduler that shares the SPI bus with other devices; the driver only sees the tick, so nothing changes for it.

On hardware (Spartan-7 xc7s50, 25 MHz, ticks at 208 Hz, LSM6DSM), watched with [fpga_scope](../../utils/fpga_scope/fpga_scope.md):

- After a cold start it passes `WHO_AM_I` (`0x6A`) and the configuration and stays in the sample loop.
- One burst every 120192 clocks with CS low for about 832 clocks (104 SCK cycles of 8 clocks).
- At rest and flat the accelerometer reads a total of 1.01 g, with about 3.5 LSB (0.9 mg) rms of noise; the gyroscope shows offsets of about 1 to 3 dps and about 1 LSB of noise. Moving the board, the total stays near 1 g while gravity moves between the axes, and the gyroscope follows the movement: byte order, sign and accelerometer scale are right.
- New samples arrive at 206 Hz with the 208 Hz ODR.
- With `p_i2c_disable = 1` and an LPS22HB barometer sharing the bus (2026-10-16): the IMU still identifies, configures and reads correctly, and the barometer works alongside it.

## Recreating the module

To rebuild this driver from scratch against a different SPI master or from another language, the essential pieces are:

1. An SPI master capable of arbitrary-length, MSB-first, mode-0 or true mode-3 transactions (this driver uses one command byte followed by N data bytes per transaction, N being 1 for single-register access or 12 for the sensor burst).
2. A power-up sequence: write `SW_RESET` to `CTRL3_C`, wait for reboot, read and check `WHO_AM_I`.
3. A configuration sequence: write `CTRL3_C` (`BDU=1`), `CTRL1_XL` (ODR/FS), `CTRL2_G` (ODR/FS), using the register layouts and code tables above.
4. A steady-state loop: at the configured sample rate, issue a single burst read of `OUTX_L_G..OUTZ_H_XL` (12 bytes starting at `0x22`) and split the result into the 6 signed 16-bit axis values, low byte first per axis, in the order gyro X, Y, Z then accel X, Y, Z.

## Changelog

- **v1.1.0** (2026-10-25): new parameter `p_i2c_disable` (default 0, existing instantiations unchanged): writes `CTRL4_C.I2C_disable` for a bus shared with other devices. Ported from the Drone FPGA_SOM project, where it runs on hardware with the LPS22HB barometer since 2026-10-16. The testbench runs with both values.
- **v1.0.0** (2026-10-15): first release in the handbook, from the Drone FPGA_SOM project as tested there on hardware on 2026-10-15. Needs `spi_master.v` with `p_cpha` (handbook SPI module, same date).
