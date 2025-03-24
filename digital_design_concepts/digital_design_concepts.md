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

*Example 3: Non-blocking Assignment (`<=`)*

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

### Synthesis and Implementation 

**What are leaf cells?**

Leaf cell means cells which are self contained ie cells which don't instantiate any other cells in them or where the hierarchy stops ie there are no more branches in the tree ergo leaf.
