import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, Timer, Event
import random

# Driver
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

# Monitor
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

# Scoreboard
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


# Test case
async def run_counter_test(dut, driver, monitor, scoreboard, ip_module_val):

    bit_width = len(dut.ip_module)
    max_val = 2**bit_width - 1

    assert ip_module_val <= max_val, f"ip_module value {ip_module_val} exceeds {bit_width} bits"
    dut._log.info(f"Testing with pw_counter_module={bit_width}, ip_module={ip_module_val}")

    cocotb.start_soon(monitor.observe_n_cycles(ip_module_val))

    await driver.send(ip_module_val)

    monitor.ready.set()
    await RisingEdge(dut.clk)

    for _ in range(ip_module_val-1):
        scoreboard.add_expected(0)
        dut._log.info(f"Count={int(dut.rp_counter)} TC={dut.o_tc}, Expected 0, Monitor {int(monitor.val)}")
        await RisingEdge(dut.clk)

    scoreboard.add_expected(1)
    dut._log.info(f"Count={int(dut.rp_counter)} TC={dut.o_tc} Expected 1, Monitor {int(monitor.val)}")
    await RisingEdge(dut.clk)

    scoreboard.compare()

# Main test
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
