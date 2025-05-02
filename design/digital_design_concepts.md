## Digital Design Concepts

### Difference between Blocking vs Non-blocking?

| Feature             | **Blocking (`=`)** | **Non-Blocking (`<=`)** |
|---------------------|-------------------|-------------------------|
| **Execution Order** | Executes **immediately** within the same time step (like sequential code). | Executes **in parallel**, scheduling updates for the next time step. |
| **Use Case**        | Used for **combinational logic** (e.g., `always @(*)`). | Used for **sequential logic** (e.g., `always @(posedge clk)`). |
| **Effect on Simulation** | Can cause **race conditions** in sequential designs. | Prevents race conditions by ensuring updates happen at the correct time. |
| **Register Behavior** | Doesn't correctly model **flip-flops** or registers. | Properly models **flip-flops** and registers. |
| **Execution Example** | Executes immediately, affecting subsequent statements. | Updates all signals at the same time in a clock cycle. |
  

*Example 1: Blocking Assignment (`=`)*

```verilog
always @(*) begin
    A = B; 
    C = A;
end
```
Behavior: Since A = B executes first, C = A uses the updated value of A.

*Example 2: Non-blocking Assignment (`<=`)*

```verilog
always @(posedge clk) begin
    A <= B;
    C <= A;
end
```

Behavior: A doesn't update immediately. Instead, C gets the old value of A, because both assignments happen simultaneously at the end of the clock cycle.

*Rule of thumb*

* Use blocking for combinacional logic.
* Use non-blocking for sequential logic.

### Difference between a task and a function in Verilog?

| Característica                   | Task                              | Function                            |
|---------------------------------|-----------------------------------|--------------------------------------|
| Uso principal                   | Realizar operaciones complejas o secuenciales | Realizar operaciones combinacionales y devolver un solo valor |
| Retorno de valor                 | Opcional, usando `output`          | Obligatorio, devuelve un valor directamente |
| Tiempo de ejecución              | Puede contener declaraciones de tiempo como `#`, `@`, `wait` | No puede contener declaraciones de tiempo |
| Número de valores de retorno     | Múltiples mediante `output`        | Solo un valor de retorno             |
| Llamada desde                    | Siempre se llama desde un **procedural block** | Puede llamarse desde cualquier expresión |
| Ejecución en paralelo            | No soporta ejecución paralela      | Siempre se ejecuta de manera combinacional |
| Uso de argumentos                | Permite múltiples tipos (input, output, inout) | Solo permite argumentos de tipo `input` |
| Contexto de uso                  | Tareas complejas como testbenches y secuencias de eventos | Operaciones matemáticas, lógicas o combinacionales |
| Ejemplo de declaración           | `task add(input a, b; output sum);` | `function [7:0] add(input [7:0] a, b);` |

### Difference between wire and reg?

The net (wire, tri) is used for physical connection between structural elements. Value is assigned by a continuous assignment or a gate output or port of a module. It can not store any value. The values can be either read or assigned. Default value is z.

The register (reg, integer, time, real, real-time) represents an abstract data storage element and they are not the physical registers. Value is assigned only within an initial or an always statement.
It can store the value. Default value is x.

### Difference between a flip flop and a latch?

| Feature            | **Flip-Flop** | **Latch** |
|--------------------|--------------|-----------|
| **Triggering**     | Edge-triggered (rising or falling edge of the clock). | Level-sensitive (transparent when enable is high). |
| **Clock Dependency** | Requires a clock signal to change state. | Can change state anytime when enabled. |
| **Storage Type**   | Synchronous storage element. | Asynchronous storage element. |
| **Timing Control** | Captures data only at clock edges. | Follows input while enabled, holds value otherwise. |
| **Power Consumption** | Higher power consumption (clocking overhead). | Lower power (but can have glitches). |
| **Common Usage**   | Registers, counters, memory elements. | Buffering, metastability handling (synchronizers). |

*Latches Can Cause Timing Issues:*

Since latches are transparent while enabled, they can introduce glitches in high-speed circuits.

Flip-flops are safer because they only update on clock edges, reducing race conditions.

*D-latch in Verilog*

```verilog
module d_latch (
    input logic D,      // Data input
    input logic En,     // Enable signal
    output logic Q,     // Output
    output logic Qn     // Complementary output
);

    always @(*) begin
        if (En) begin
            Q  = D;
            Qn = ~D;
        end
    end

endmodule
```

*D-flip-flop*

```verilog
module d_flip_flop (
    input logic D,      // Data input
    input logic clk,    // Clock input
    input logic rst_n,  // Active-low reset
    output logic Q,     // Output
    output logic Qn     // Complementary output
);

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            Q  <= 0;  
            Qn <= 1;
        end else begin
            Q  <= D;  
            Qn <= ~D;
        end
    end

endmodule
```

### What are regular delay control and Intra-assignment delay control?

The regular delay control delays the execution of the entire statement by a specified value. The non-zero delay is specified at the LHS of the procedural statement.

*Example: #5 data = i_value;*

In this case, the result signal value will be updated after 5-time units for change happen in its input. 

Intra-assignment delay control delays computed value assignment by a specified value. The RHS operand expression is evaluated at the current simulation time and assigned to the LHS operand after a specified delay value.

*Example: data = #5 i_value;*

### What is #0 in Verilog and its usage?

Zero delay control is used to control execution order when multiple procedural blocks try to update values of the same variable. Both always and initial blocks execution order is non-deterministic as they start evaluation at the same simulation time. The statement having zero control delay executes last, thus it avoids race conditions.

```verilog
reg [2:0] data;
initial begin 
  data = 2;
end
initial begin 
  #0 data = 3;
end
```

Without zero delay control, the ‘data’ variable may have a value of either 2 or 3 due to race conditions. Having zero delay statement as specified in the above code guarantees the outcome to be 3. However, it is not recommended to assign value to the variable at the same simulation time.


### What is `timescale?

It is a ‘compile directive’ and is used for the measurement of simulation time and delay.

```verilog
`timescale <time_unit>/<time_precision>
```

- time_unit: Measurement for simulation time and delay.
- time_precision: Rounding the simulation time values means the simulator can at least advance by a specified value.
