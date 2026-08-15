### 🔹 2-Level Modulator

Module that generates the PWM signals for a 3-phase 2-level power converter. Three modulating signals (R, S, T), in signed fixed point format S[16,15], are compared against a common carrier to produce the PWM output of each phase. The carrier can be configured as triangular (double edge) or sawtooth (single edge), and its switching period is set through `i16_period`.

✔️ Verified via testbench, injecting a balanced 3-phase sinusoidal modulating set and checking the resulting PWM waveforms.

🧪 Status: Simulation only, not yet tested on real hardware.

📁 [Source Code](source/modulador_2lvl.v)

📁 [Testbench](test/modulador_tb.sv)

📌 Instantiation:

```verilog
modulador_2lvl modulador_2lvl (
    .clk(),
    .rst(),
    .i_on(), /* transistors on */
    .i_enable_sawtooth(), /* if 0 carrier is triangular if 1 carrier is sawtooth */
    .i16_period(), /* TRIANGULAR: period = fclk / (2 * fsw) - SAWTOOTH: period = fclk / fsw */
    .i16_modulator_r(), /* modulator signal R S[16,15] */
    .i16_modulator_s(), /* modulator signal S S[16,15] */
    .i16_modulator_t(), /* modulator signal T S[16,15] */
    .o3_pwm() /* pwm output HIGH, phase R - S - T */
);
```
