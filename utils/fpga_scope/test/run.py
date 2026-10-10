import os
import time 
import subprocess
import platform
import sys
import shutil
import matplotlib.pyplot as plt
from os.path import exists

SOURCES_DIR = "../source/"
TEST_SOURCES_DIR = ""

UART_SOURCES_DIR = "../../../modules/uart/source/"

VERILOG_SOURCES = SOURCES_DIR + "scope_top.v"
VERILOG_SOURCES += " " + SOURCES_DIR + "scope_cmd_if.v"
VERILOG_SOURCES += " " + SOURCES_DIR + "scope_ctrl.v"
VERILOG_SOURCES += " " + SOURCES_DIR + "scope_trigger.v"
VERILOG_SOURCES += " " + SOURCES_DIR + "scope_decimator.v"
VERILOG_SOURCES += " " + SOURCES_DIR + "scope_streamer.v"
VERILOG_SOURCES += " " + SOURCES_DIR + "scope_capture_buffer.v"
VERILOG_SOURCES += " " + UART_SOURCES_DIR + "uart_tx.v"
VERILOG_SOURCES += " " + UART_SOURCES_DIR + "uart_rx.v"

TEST_SOURCE = "./scope_tb.v"

TOPLEVEL = "scope_tb"

# TEST EXECUTION
################

simulador = "iverilog"

# Delete previous files
if exists("./sim_log"):
  print("Removing last sim_log file")
  os.remove("./sim_log")

process = subprocess.Popen("iverilog -o testbench.vvp -s " + TOPLEVEL + " -g2005-sv -gstd-include -grelative-include " + TEST_SOURCE + " " + VERILOG_SOURCES, shell=True)
print(process.wait())
process = subprocess.Popen("vvp -l sim_log testbench.vvp", shell=True)
print(process.wait())
os.remove("./testbench.vvp")


exit()
