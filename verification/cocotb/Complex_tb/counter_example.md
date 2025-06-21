## Using advanced verification components: counter example

The following steps will describe how to verify a parametrized up-counter, the files needed are in this folder.

1. Define the Driver:

The driver is responsible for applying inputs to the DUT:

- init: constructor function, it passes the dut
- reset: applies a reset pulse
- send: sets the ip_module input value

```python
class CounterDriver:
  
  def __init__(self, dut):
    self.dut = dut

  async def reset(self):
    self.dut.rst.value = 1
    await RisingEdge(self.dut.clk)
    self.dut.rst.value = 0
    await RisingEdge(self.dut.clk)

  async def send(self, ip_module_val):
    self.dut.ip_module.value = ip_module_val
```

Notice that the parameter pw_counter_module is a Verilog parameter, which means it must be set before the simulation is compiled and run. This is done via the Makefile or the simulator command line.

| Task                  |	Where It Happens | How                               |
|-----------------------|------------------|-----------------------------------|
| Set pw_counter_module	| Makefile / CLI	 | make PW_COUNTER_MODULE=6          |
| Use pw_counter_module	| Verilog	         | parameter pw_counter_module = ... |
| React to it in test	  | Python	         | len(dut.ip_module)                |

2. Define the Monitor:

The monitor observes DUT outputs and passes them to scoreboard:

- init: constructor function
- observe: watches *o_tc* during n cycles after a rising clock edge and calls the callback with its value. A callback is simply a function that is passed as an argument to another function or object, with the intention that it will be called later — usually when a specific event occurs.

```python
class CounterMonitor:

  def __init__(self, dut, callback):
    self.dut = dut
    self.val = 10
    self.callback = callback
    self.ready = Event()  # sync signal

  async def observe_n_cycles(self, n):
    await self.ready.wait()
    for _ in range(n):
      await RisingEdge(self.dut.clk)
      val = int(self.dut.o_tc.value)
      self.val = val
      self.callback(val)
```

3. Define the scoreboard:

The scoreboard compares expected and actual outputs:

- add_expected: adds expected output value
- add_actual: adds actual output value
- compare: compares actual output with expected and raises an error if the differ

```python
class CounterScoreboard:

  def __init__(self):
    self.expected = []
    self.actual = []

  def add_expected(self, value):
    self.expected.append(value)

  def add_actual(self, value):
    self.actual.append(value)

  def compare(self):
    assert self.actual == self.expected, f"Mismatch! Expected {self.expected}, got {self.actual}"
    # Clean lists for next test
    self.expected = []
    self.actual = []
```

4. Test flow:

* Start the clock: A 10 ns clock is created using cocotb.clock.Clock and started asynchronously with cocotb.start_soon().
* Initialize the driver and scoreboard: A CounterDriver is instantiated to control inputs, and a CounterScoreboard is used to track expected vs. actual outputs.
* Connect the monitor to the scoreboard: A CounterMonitor is created with a callback that forwards observed values to the scoreboard using scoreboard.add_actual().
* Reset the DUT: The reset() method of the driver is awaited to ensure the DUT starts from a known state.
* Determine input width: The bit width of the DUT’s ip_module input is read using len(dut.ip_module) to calculate valid input limits.
* Generate a random test value: A random integer is selected between 1 and the maximum value allowed by the input width.
* Run the test scenario: The run_counter_test() coroutine is called with all components and the test value to drive the DUT and perform checking.

```python
@cocotb.test()
async def test_counter(dut):
    
  clock = Clock(dut.clk, 10, units="ns")
  cocotb.start_soon(clock.start())

  driver = CounterDriver(dut)
  scoreboard = CounterScoreboard()

  def monitor_callback(value):
      scoreboard.add_actual(value)

  monitor = CounterMonitor(dut, monitor_callback)

  await driver.reset()

  bit_width = len(dut.ip_module)
  max_val = 2**bit_width - 1

  value = random.randint(1, max_val)

  await run_counter_test(dut, driver, monitor, scoreboard, value)
```

5. Test scenario:

* Validate the input value: The bit width of ip_module is determined, and an assertion ensures ip_module_val fits within this width.
* Log the test configuration: The bit width and test value are logged for traceability and debugging.
* Start the monitor coroutine: monitor.observe_n_cycles(ip_module_val) is scheduled to run asynchronously but will wait until explicitly triggered.
* Apply stimulus to DUT: The driver sends the ip_module_val to the DUT using driver.send().
* Trigger monitoring: The monitor is activated by setting monitor.ready right before the DUT processes the new input.
* Sync with DUT clock: The test waits for one rising clock edge to allow the DUT to latch the input value.
* Feed expected output to scoreboard: For ip_module_val - 1 clock cycles, a 0 is expected on o_tc, and each step is logged.
* Expect terminal count signal: After the countdown, a final 1 is expected on o_tc, with logging for traceability.
* Verify correctness: The scoreboard compares the list of expected vs. actual outputs to check for test pass/fail.

```python
async def run_counter_test(dut, driver, monitor, scoreboard, ip_module_val):
    
  # Check ip module val
  bit_width = len(dut.ip_module)
  max_val = 2**bit_width - 1

  assert ip_module_val <= max_val, f"ip_module value {ip_module_val} exceeds {bit_width} bits"
  dut._log.info(f"Testing with pw_counter_module={bit_width}, ip_module={ip_module_val}")

  # Starts monitor but not launch it until event raises
  cocotb.start_soon(monitor.observe_n_cycles(ip_module_val))

  # Set DUT stimuli
  await driver.send(ip_module_val)

  # Launch observation right before the first edge
  monitor.ready.set()

  # Wait one clk to the DUT notice the value seted
  await RisingEdge(dut.clk)


  # Generate the expected sequence: ip_module_val-1 times 0 and after 1
  for _ in range(ip_module_val-1):
      scoreboard.add_expected(0)
      dut._log.info(f"Count={int(dut.rp_counter)} TC={dut.o_tc}, Expected 0, Monitor {int(monitor.val)}")
      await RisingEdge(dut.clk)

  scoreboard.add_expected(1)
  dut._log.info(f"Count={int(dut.rp_counter)} TC={dut.o_tc} Expected 1, Monitor {int(monitor.val)}")
  await RisingEdge(dut.clk)

  # Compare complete lists
  scoreboard.compare()
```

6. Run the test providing the PW_COUNTER_MODULE value:

```bash
make PW_COUNTER_MODULE=6
```

### Conclusion

When performing this kind of cocotb-based test for a sequential digital module like a counter, several tricky synchronization and coordination issues need to be carefully handled. Here's a breakdown of key considerations:

🔁 **Clock Synchronization**

Everything is clock-driven: In synchronous designs, all events (input sampling, output changes) happen on clock edges, so you must carefully align your stimulus and monitoring with the rising edge of the clock.

Wait at least one cycle after applying input: Signals like ip_module must be stable before the rising edge to be correctly latched by the DUT.

⏱ **Timing Between Driver and Monitor**

Race conditions: If the monitor starts observing before the DUT processes the input, it may capture irrelevant or invalid data.

Manual control of monitor activation: In the test, monitor.observe_n_cycles() is launched early, but doesn't start capturing until monitor.ready.set() is called — after the stimulus is applied. This ensures correct alignment between observation and the DUT's active behavior.

Edge-sensitive behavior: Monitoring should typically begin on the first rising edge after the DUT receives input. Any mismatch here can lead to off-by-one errors in expected vs. actual output.

📋 **Scoreboard Accuracy**

Expected values must match DUT exactly: The test must predict precisely how long o_tc should remain 0 before it turns 1, based on the input value. Even a single misplaced expected value can cause the test to fail.

Timing of add_expected calls: Each expected value should be added immediately before or in parallel with the await RisingEdge(dut.clk) that captures the actual value. This keeps both timelines in sync.

🧪 **Input Validity**

Bit-width awareness: Inputs like ip_module must not exceed the declared signal width. The test safeguards against this by dynamically computing the bit width and asserting bounds.

Random inputs: Using randomized inputs improves test coverage, but increases the risk of timing mismatches or edge-case bugs — especially for small or max values.

🔄 **Reset Behavior**

Always reset before test logic starts: Ensuring the DUT starts from a clean state is critical. Skipping or improperly timing the reset can cause false negatives.

Reset must also be aligned with the clock: Reset pulses should be asserted/deasserted on appropriate clock edges to avoid metastability in simulation.

📋 **Observability and Logging**

Log internal DUT values (like rp_counter) during simulation to help debug discrepancies.

Make logs match expectations: Ensure that logs include cycle number, DUT outputs, expected values, and monitor outputs to simplify traceability.

🧵 **Coroutines and Parallelism**

Asynchronous execution (e.g., start_soon()): The test depends on several components running in parallel (driver, monitor, clock), and cocotb uses Python coroutines for this. Misusing await or failing to start_soon() a process can lead to deadlocks or missed signals.

Ensure all needed coroutines are running before stimulus is sent or verification begins.

