# ✅ Code Modules

Esta sección contiene módulos de diseño digital que han sido desarrollados, verificados y probados con éxito. La idea es construir una pequeña biblioteca reutilizable que puedas integrar fácilmente en futuros proyectos personales o profesionales.

## 📦 Módulos Disponibles

### 🔹 UART Transmitter (uart_tx)

Módulo secuencial que transmite datos en serie utilizando el protocolo UART.

✔️ Verificado mediante testbench con estímulos de distintos baud rates, tamaños de tramas y valores transmitidos.

🧪 Estado: Probado en HW real utilizando un FTDI conectado al ordenador.

📁 [Código fuente](uart/source/uart_tx.v)

📁 [Testbench](uart/test/uart_tb.v) 

📌 Instancia:

```verilog
uart_tx # (
    .p_preescaler(), /* clock preescaler to set baudrate */
    .p_data_buffer() /* number of bytes to send */
) uart_tx (
    .clk(), 
    .rst(), /* synchronous reset */
    .ip_data(), /* data to send */
    .i_dv(), /* input data valid */
    .o_ready(), /* module ready to accept new data */
    .o_tx() /* uart transmission line */
);
```

### 🔹 UART Receiver (uart_rx)

Módulo secuencial que recibe datos en serie utilizando el protocolo UART.

✔️ Verificado mediante testbench con estímulos de distintos baud rates, tamaños de tramas y valores transmitidos.

🧪 Estado: Probado en HW real utilizando un FTDI conectado al ordenador.

📁 [Código fuente](uart/source/uart_rx.v)

📁 [Testbench](uart/test/uart_tb.v) 

📌 Instancia:

```verilog
uart_rx #(
    .p_preescaler(), /* Prescaler for baudrate */
    .p_data_buffer() /* Indicates number of bytes to receive */
) uart_rx (
    .clk(), /* Input clock */
    .rst(), /* Input reset */
    .i_rx(),	/* Input rx pin */
    .orp_data(),	/* Parallel data port */
    .or_dv() /* New data available in data port */ 
);
```