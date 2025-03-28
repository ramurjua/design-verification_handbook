## Digital Design Concepts

### Timming Analysis

In digital designs each and every flip-flop has some restrictions related to the data with respect to the clock. There is always a region around the clock edge in which input data should not change at the input. If the data changes within this window, we cannot guarantee the output. The output can be the result of either of the previous input, the new input or metastability. This window is marked by the setup time and the hold time. 

* Setup time: is defined as the minimum amount of time required to for the input to a FF to be stable before a clock edge. 
* Hold time: is defined as the minimum amount of time required for the input to a FF to be stable after a clock edge. 

Mitigating setup violation:
1. Decreasing clk->q delay of launching flop 
2. Decreasing the propagation delay of the combinational cloud 
3. Reducing the setup time requirement of capturing flop 
4. Increasing the skew between capture and launch clocks
5. Increasing the clock period

Mitigating hold violation: We can meet the hold requirement by:
1. Increasing the clk->q delay of launching flop
2. Decreasing the hold requirement of capturing flop
3. Decreasing clock skew between capturing clock and launching flip-flops

**How does setup and hold time relate to clock frequency?**

The maximum clock frequency is the mimum clock period (T), and the minimum period allowed for a circuit is equal to the addition of setup time (tsu), propagation time (tp) and hold time (th). The propagation delay is the amount of time it takes for signals to pass between two Flip-Flops.

fmax = 1.0 / (tsu + tp + th)

TODO: revisar apuntes de clase sobre las ecuaciones y demas

**What is metastability?**

Metastability is a phenomenon of unstable equilibrium in digital electronics in which the sequential element is not able to resolve the state of the input signal; hence, the output goes into unresolved state for an unbounded interval of time. 

The flop starts to capture the data and output also starts to transition. But, before output has changed its state, the input is cut-off from the output as clock edge has arrived. The output is, then, left hanging between state ‘0’ and state ‘1’. Theoretically, the output may remain in this state for an indefinite period of time. But, given the time to settle down, the output will eventually settle to either its previous state or the new state. Thus, the effect of signal present at input of flop may not travel to the output of the flop partly or completely. The metastability failure is said to have occurred if the output has not resolved itself by the time it must be available for use.

**How to read timming summary?**

Timing analysis is available anywhere in the flow after synthesis. You can review the Timing Summary report files automatically created by the Synthesis and Implementation runs.

In a synthesized design, the AMD Vivado™ IDE timing engine estimates the net delays based on connectivity and fanout. The accuracy of the delays is greater for nets between cells that are already placed by the user. There can be larger clock skew on paths where some of the cells have been pre-placed, such as I/Os and GTs.

In an implemented design, the net delays are based on the actual routing information. You must use the Timing Summary report for timing signoff if the design is completely routed.

![Timming Symmary](timming_report.png)

### Synchronizers

https://vlsiuniverse.blogspot.com/2013/09/synchronization-schemes.html 

### Code

**Difference between Blocking vs Non-blocking?** 

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

**Difference between a task and a function in Verilog?**

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

**Difference between aire and reg?**

The net (wire, tri) is used for physical connection between structural elements. Value is assigned by a continuous assignment or a gate output or port of a module. It can not store any value. The values can be either read or assigned. Default value is z.

The register (reg, integer, time, real, real-time) represents an abstract data storage element and they are not the physical registers. Value is assigned only within an initial or an always statement.
It can store the value. Default value is x.

**Difference between a flip flop and a latch**

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

**What are regular delay control and Intra-assignment delay control?**

The regular delay control delays the execution of the entire statement by a specified value. The non-zero delay is specified at the LHS of the procedural statement.

*Example: #5 data = i_value;*

In this case, the result signal value will be updated after 5-time units for change happen in its input. 

Intra-assignment delay control delays computed value assignment by a specified value. The RHS operand expression is evaluated at the current simulation time and assigned to the LHS operand after a specified delay value.

*Example: data = #5 i_value;*

**What is #0 in Verilog and its usage?**

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


**What is `timescale?**

It is a ‘compile directive’ and is used for the measurement of simulation time and delay.

```verilog
`timescale <time_unit>/<time_precision>
```

- time_unit: Measurement for simulation time and delay.
- time_precision: Rounding the simulation time values means the simulator can at least advance by a specified value.

### Synthesis and Implementation 

**What is infer latch means? How can you avoid it?**

Infer latch means creating a feedback loop from the output back to the input due to missing if-else condition or missing ‘default’ in a ‘case’ statement. 

Infer latch indicates that the design might not be implemented as intended and can result in race conditions and timing issues.

How to avoid It:

- Always use all branches in the ‘if’ and ‘case’ statements.
- Use default in the ‘case’ statement.
- Have a proper code review.
- Use lint tools, and logical-equivalence-check tools

**What are leaf cells?**

Leaf cell means cells which are self contained ie cells which don't instantiate any other cells in them or where the hierarchy stops ie there are no more branches in the tree ergo leaf.
