# Writes an .mcs file into the FPGA's SPI configuration flash through the
# Raspberry Pico JTAG (xvcd-pico). Run by program_flash.bat, which starts
# xvcd-pico first; on its own: vivado -mode batch -source program_flash.tcl
# with xvcd-pico already running.

# --------- USER INPUTS ----------
set project_name        IMU_test
set mcs_file            ../output/$project_name.mcs   ;# written by build_project.tcl
set xvc_url             localhost:2542                ;# where xvcd-pico listens
set fpga_device         xc7s50_0                      ;# as listed by get_hw_devices
set flash_part          s25fl128l-spi-x1_x2_x4        ;# flash fitted on the board, see get_cfgmem_parts
set connect_delay_ms    5000                          ;# wait after connecting: the JTAG chain takes a while to show up
set connect_attempts    3                             ;# tries before giving up, the same wait before each retry
# --------------------------------

proc fail {msg} {
    puts ">> ERROR: $msg <<"
    exit 1
}

if {![file exists $mcs_file]} {
    fail "$mcs_file not found, run build_project.tcl first"
}
set mcs_file [file normalize $mcs_file]

# Supress messages with severity info
set_msg_config -suppress -severity INFO

# Connect to the Pico through xvcd-pico. The devices take a while to be
# detected, so wait before opening the target; if they are still not there,
# re-register the target (disconnect / connect, as Vivado asks) and try again
open_hw_manager
connect_hw_server -allow_non_jtag
set device ""
set err ""
for {set attempt 1} {$attempt <= $connect_attempts} {incr attempt} {
    if {$attempt > 1} {
        catch {close_hw_target}
        disconnect_hw_server
        connect_hw_server -allow_non_jtag
    }
    puts ">> INFO: waiting [expr {$connect_delay_ms / 1000.0}] s for the JTAG chain, try $attempt of $connect_attempts <<"
    after $connect_delay_ms
    if {![catch {open_hw_target -xvc_url $xvc_url} err]} {
        catch {set device [lindex [get_hw_devices $fpga_device] 0]}
        if {$device ne ""} break
        set err "$fpga_device not in the chain: [get_hw_devices]"
    }
}
if {$device eq ""} {
    fail "$fpga_device not found at $xvc_url after $connect_attempts tries: is the board powered, the Pico wired to its JTAG pins and xvcd-pico running? (last error: $err)"
}
set part [lindex [get_cfgmem_parts $flash_part] 0]
if {$part eq ""} {
    fail "unknown flash part $flash_part"
}

# Configuration memory: erase, program and verify the range the file uses
create_hw_cfgmem -hw_device $device $part
set cfgmem [get_property PROGRAM.HW_CFGMEM $device]
refresh_hw_device $device

set_property PROGRAM.FILES [list $mcs_file] $cfgmem
set_property PROGRAM.PRM_FILE {} $cfgmem
set_property PROGRAM.ADDRESS_RANGE {use_file} $cfgmem
set_property PROGRAM.UNUSED_PIN_TERMINATION {pull-none} $cfgmem
set_property PROGRAM.BLANK_CHECK 0 $cfgmem
set_property PROGRAM.ERASE 1 $cfgmem
set_property PROGRAM.CFG_PROGRAM 1 $cfgmem
set_property PROGRAM.VERIFY 1 $cfgmem
set_property PROGRAM.CHECKSUM 0 $cfgmem

# Load the helper bitstream that lets JTAG reach the flash, then program it
puts ">> INFO: programming $mcs_file into $flash_part <<"
if {[catch {
    create_hw_bitstream -hw_device $device [get_property PROGRAM.HW_CFGMEM_BITFILE $device]
    program_hw_devices $device
    refresh_hw_device $device
    program_hw_cfgmem -hw_cfgmem $cfgmem
} err]} {
    fail "flash programming failed: $err"
}

close_hw_target
disconnect_hw_server
close_hw_manager

puts "\n << FLASH PROGRAMMED AND VERIFIED >>"
puts " >> Power cycle the board to boot the new design from the flash <<"

exit 0
