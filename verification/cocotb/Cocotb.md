# Cocotb

Cocotb is a powerful verification framework that allows you to write testbenches for digital hardware using Python instead of traditional HDL languages like Verilog or VHDL. It simplifies the testing process by leveraging Python's readability, extensive libraries, and advanced features such as coroutines and randomization. This makes it easier to write, debug, and scale complex test scenarios. Cocotb also integrates seamlessly with existing simulators, enabling modern software practices like unit testing and continuous integration in hardware development workflows.

📂 [Create a simple testbench: 4-bits adder example](Simple_tb/adder_example.md) 
📂 [Using advanced verification components: counter example](Complex_tb/counter_example.md) 

## Key Concepts in Cocotb

### 1. Coroutines (async def)

Coroutines are functions that can pause execution using await, allowing simulation of time or event-based behavior.

```python
@cocotb.test()
async def my_test(dut):
    await RisingEdge(dut.clk)
```

### 2. Triggers

Triggers are events that synchronize test execution with the simulator:

* RisingEdge(signal): wait for rising edge
* FallingEdge(signal): wait for falling edge
* Timer(time, units='ns'): wait for a specific time
* ReadOnly(): wait until the simulator finishes the current cycle

### 3. Parallel Execution (fork/join)

You can launch tasks in parallel using cocotb.start_soon() similarly as with verilog fork join instruction.

```verilog
initial begin
  fork
    task1();
    task2();
  join
  $display("Both tasks completed");
end
```

```python
async def task1():
    await Timer(10, units='ns')
    cocotb.log.info("Task 1 done")

async def task2():
    await Timer(20, units='ns')
    cocotb.log.info("Task 2 done")

@cocotb.test()
async def test_parallel(dut):
    cocotb.start_soon(task1())
    cocotb.start_soon(task2())
    await Timer(30, units='ns')
    cocotb.log.info("Both tasks should be done")
```

### 4. Subroutines (task)

Reusable functions are defined using async def

```python
async def reset(dut):
    dut.rst.value = 1
    await Timer(10, units='ns')
    dut.rst.value = 0
```

### 5. Logging and Errors

* cocotb.log.info("message"): print information
* assert condition, "message": raise error if condition fails

## Verilog vs. Cocotb – Feature Equivalents

| Verilog Feature         | Cocotb Equivalent                                  | Description |
|-------------------------|----------------------------------------------------|-------------|
| `initial` / `always`    | `@cocotb.test()` + `async def`                    | Test blocks |
| `posedge clk`           | `await RisingEdge(dut.clk)`                       | Wait for rising edge |
| `wait (cond)`           | `await ReadOnly(); if cond:` or `await Event()`   | Wait for condition |
| `task`                  | `async def name():`                               | Asynchronous subroutine |
| `fork/join`             | `cocotb.start_soon(func())`                       | Run in parallel |
| `$display(...)`         | `cocotb.log.info(...)`                            | Print messages |
| `$error(...)`           | `assert cond, "message"`                          | Assertion failure |


## Advanced verification componentes: What Are Drivers, Monitors, and Scoreboards?

These are testbench components that help you organize your verification code in a clean and reusable way. They are inspired by object-oriented verification methodologies like UVM (Universal Verification Methodology), but adapted to Python and Cocotb.

### 1. Drivers – Stimulus Generators

A driver is a component that sends inputs to the DUT (Device Under Test). It encapsulates the logic for applying values to input signals, often in a reusable and parameterized way.

* Keeps test code clean
* Allows reuse across multiple tests
* Makes it easier to randomize or sequence inputs

*Example Use Case*

Instead of writing this in every test:

```python
dut.a.value = 5
dut.b.value = 3
await Timer(2, units='ns')
```

You write:

```python
await driver.send(5, 3)
```

### 2. Monitors – Output Observers

A monitor is a passive component that watches the DUT’s outputs and records or reports them. It does not drive any signals — it just listens.

* Separates observation from checking
* Can log or store outputs for later comparison
* Useful for coverage collection or debugging

*Example Use Case*

Instead of checking outputs manually:

```python
await RisingEdge(dut.clk)
observed = dut.sum.value
```

You write:

```python
await monitor.observe()
# monitor stores or logs the value internally
```

### 3. Scoreboards – Output Checkers

A scoreboard is a component that compares the expected outputs (from a model or prediction) with the actual outputs (from the DUT). It’s the core of a self-checking testbench.

* Automates result checking
* Helps detect mismatches
* Makes your testbench scalable and maintainable

*Example Use Case*

Instead of writing:

```python
assert dut.sum.value == expected
```

You write:

```python
scoreboard.add_expected(expected)
scoreboard.add_actual(dut.sum.value)
scoreboard.check()
```

### How They Work Together

* Driver sends inputs to the DUT.
* Monitor observes outputs from the DUT.
* Scoreboard compares expected vs actual outputs.
