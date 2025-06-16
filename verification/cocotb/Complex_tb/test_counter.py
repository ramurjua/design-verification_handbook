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
        self.ready = Event()  # señal de sincronización

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
        # Limpia para el siguiente test
        self.expected = []
        self.actual = []


# Test case
async def run_counter_test(dut, driver, monitor, scoreboard, ip_module_val):
    bit_width = len(dut.ip_module)
    max_val = 2**bit_width - 1

    assert ip_module_val <= max_val, f"ip_module value {ip_module_val} exceeds {bit_width} bits"
    dut._log.info(f"Testing with pw_counter_module={bit_width}, ip_module={ip_module_val}")

   # 1. Arranca el monitor pero está esperando el evento
    cocotb.start_soon(monitor.observe_n_cycles(ip_module_val))

    # 2. Envía estímulo al DUT
    await driver.send(ip_module_val)

    # 3. Lanza la observación exactamente antes del primer flanco
    monitor.ready.set()

    # 4. Ahora sí, espera un ciclo para que el DUT registre
    await RisingEdge(dut.clk)


    # Genera la secuencia esperada: ip_module_val-1 veces 0 y luego 1
    for _ in range(ip_module_val-1):
        scoreboard.add_expected(0)
        dut._log.info(f"Count={int(dut.rp_counter)} TC={dut.o_tc}, Expected 0, Monitor {int(monitor.val)}")
        await RisingEdge(dut.clk)

    scoreboard.add_expected(1)
    dut._log.info(f"Count={int(dut.rp_counter)} TC={dut.o_tc} Expected 1, Monitor {int(monitor.val)}")
    await RisingEdge(dut.clk)

    # Compara listas completas
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
    num_tests = 5

    random_values = [random.randint(1, max_val) for _ in range(num_tests)]

    """ for ip_module_val in random_values: """
    await run_counter_test(dut, driver, monitor, scoreboard, 4)
