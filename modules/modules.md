# Code Modules

This section contains digital design modules that have been successfully developed, verified, and tested. The goal is to build a reusable library that can be easily integrated into future personal or professional projects.

### 🔹 UART Transmitter & Receiver

[UART Transmitter & Receiver](uart/uart.md) sequential modules to transmit and receive data serially using the UART protocol.

### 🔹 SPI Master & Slave

[SPI Master & Slave](spi/spi.md) modules to implement a master and slave spi agents.

### 🔹 Clark Park Direct & Inverse & DDS

[Clark Park Direct & Inverse & DDS](clarkpark/clarkpark.md) modules that performs the clark-park transformations in amplitud invariant mode and clark-park inverse transformations. There is also a module to generate sin and cos waveforms of selected frequency.

### 🔹 LSM6DSM IMU SPI driver

[LSM6DSM IMU SPI driver](imu_lsm6dsm/imu_lsm6dsm.md) for the ST LSM6DSM accelerometer and gyroscope (also LSM6DSL / LSM6DSO): identifies and configures the chip, then reads the six axes as signed 16-bit values on every tick. Uses the SPI master.

### 🔹 LPS22HB barometer SPI driver and height

[LPS22HB barometer SPI driver and height](baro_lps22hb/baro_lps22hb.md) for the ST LPS22HB pressure sensor: identifies and configures the chip, then reads pressure (24-bit, 4096 LSB/hPa) and temperature on every tick, plus an optional module that turns the pressure into a height above a reference taken on request, in 2 cm steps. Uses the SPI master, in the same SPI mode as the LSM6DSM IMU driver.

### 🔹 2-Level Modulator

[2-Level Modulator](modulador_2lvl/modulador_2lvl.md) module that generates the PWM signals for a 3-phase 2-level power converter from three modulating signals, using a configurable triangular or sawtooth carrier.

## Releases

Each module is released on its own. Its page has a `🏷️ Version` line and a changelog at the end, and every release is a git tag on `main` named `<module>/v<major>.<minor>.<patch>`, for example `imu_lsm6dsm/v1.0.0`. A project that copies a module notes the tag it copied, and can see what changed since with `git log <tag>..main -- modules/<module>`.

- **major**: the ports or parameters change in a way that breaks an existing instantiation.
- **minor**: new features that keep existing instantiations working.
- **patch**: fixes that change no interface.

Modules from before this scheme (UART, SPI, Clark Park, 2-level modulator) have no version yet.
