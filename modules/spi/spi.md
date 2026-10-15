### 🔹 SPI Master

Module that transmits and reads data using the SPI protocol actuating as a master. Take into account chip select logic is outside the modules scope since it can be different depending on its use. 

✔️ Verified via testbench with stimuli for various clock preescalers, cpol configurations, frame sizes, and transmitted values.

🧪 Status: Tested on real hardware using components in PCB that communicates through SPI. Mode 3 (`p_cpol = 1`, `p_cpha = 1`) tested on real hardware with an LSM6DSM IMU (2026-10-15, through the [IMU driver](../imu_lsm6dsm/imu_lsm6dsm.md), whose testbench checks every SCK edge against mode 3). The SPI testbench itself only drives transfers and has no automatic checks.

📁 [Source Code](source/spi_master.v)

📁 [Testbench](test/spi_tb.v)

📌 Instantiation:

```verilog
spi_master #(
    .p_prescaler(), /* spi clock prescaler */
    .p_cpol(),	/* clock polarity: sck idle level */
    .p_max_data_buffer(), /* Max data buffer in bits */
    .pw_data_index(), /* Width for data index */
    .p_cpha() /* clock phase: 0 = sample on the first sck edge, 1 = on the second (cpol/cpha 0/0 = mode 0, 1/1 = mode 3) */
) spi_master (
    .clk(),
    .rst(),
    .ip_data(), /* parallel data to send */
    .ip_data_count(), /* number of bits to send */
    .i_data_valid(), /* input data ready to send */
    .orp_data(), /* parallel data readed */
    .o_data_ready(), /* SPI module ready to receive data */
    .or_mosi(), /* master output, slave input pin */
    .i_miso(), /* master input, slave output pin */
    .o_sck(), /* spi clock pin */
    .o_busy() /* 1 whenever a transaction is in progress, for external chip-select framing */
);
```

`p_cpol = 1` alone is SPI mode 2, not mode 3: MOSI changes on the rising edge a mode-3 slave samples on. For mode 3 set `p_cpha = 1` as well. `p_cpha` defaults to 0, which keeps the behaviour of the earlier version (modes 0 and 2).

### 🔹 SPI Slave

Module that transmits and reads data using the SPI protocol actuating as a slave. Take into account chip select logic is outside the modules scope since it can be different depending on its use. 

✔️ Verified via testbench with stimuli for various clock preescalers, cpol configurations, frame sizes, and transmitted values.

🧪 Status: Tested on real hardware using a MCU as master and the FPGA as Slave.

📁 [Source Code](source/spi_slave.v)

📁 [Testbench](test/spi_tb.v)

📌 Instantiation:

```verilog
spi_slave #(
    .p_data_buffer_length(), /* input data buffer length */
    .p_cpol() /* clock polarity */
) spi_slave (
    .clk(),
    .rst(),
    .ip_data_out(), /* data to send */
    .ip_data_count(), /* data bit count */
    .op_data_in(), /* data received */
    .o_data_valid(), /* new transaction finished */
    .o_busy(), /* spi interface is busy */
    .i_sclk(), /* spi sclk input */
    .i_mosi(), /* spi mosi input */
    .or_miso() /* spi miso output */
);
```