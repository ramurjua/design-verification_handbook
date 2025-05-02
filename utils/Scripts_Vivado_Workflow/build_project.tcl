# --------- USER INPUTS ----------
set project_name        ECHO_UART
set part_name           xc7a75tlfgg484-2L         ;
set mem_part            mx25l12872f-spi-x1_x2_x4  ;
set top_name            top
set xdc_file            SOM_ONE
set output_dir          ../output
set project_dir         ../project/autogen
# --------------------------------

# Create temp project
create_project $project_name $project_dir -part $part_name -force

# Add source files
add_files [ glob ../source/*.v]
add_files [ glob ../source/*.sv]
add_files [ glob ../source/*.vhd]

# Add include files
add_files [ glob ../include/*.vh]

# Add memory files
add_files [ glob ../memory_files/*.mem]

# Add constraints
add_files -fileset constrs_1 ../constraints/$xdc_file.xdc
update_compile_order -fileset sources_1

# Set top module
set_property top $top_name [current_fileset]

# Supress messages with severity info
set_msg_config -suppress -severity INFO

# Launch synthesis
launch_runs synth_1 -jobs 4
wait_on_run synth_1

if { [get_property status [get_runs synth_1]] == "failed" } {
    puts ">> ERROR: SYNTHESIS NOT COMPLETED <<"
    exit 1
} else {
    puts ">> INFO: SYNTHESIS COMPLETED SUCCESSFULLY <<"
}

open_run synth_1

# Launch implementation
launch_runs impl_1 -to_step write_bitstream -jobs 4
wait_on_run impl_1

if { [get_property status [get_runs impl_1]] == "failed" } {
    puts ">> ERROR: IMPLEMENTATION NOT COMPLETED <<"
    exit 1
} else {
    puts ">> INFO: IMPLEMENTATION COMPLETED SUCCESSFULLY <<"
}

# Create file roots
set bit_file "$project_dir/${project_name}.runs/impl_1/${project_name}.bit"
set mcs_file "$project_dir/${project_name}.runs/impl_1/${project_name}.mcs"
set ltx_file "$project_dir/${project_name}.runs/impl_1/${project_name}.ltx"

# Open implemented design
open_run impl_1

# Generate .ltx
write_debug_probes -force $ltx_file

# Generate .bit
write_bitstream -force $bit_file

# Generate .mcs
write_cfgmem -format mcs -size 16 -interface SPIx4 -loadbit "up 0x0 $bit_file" -file $mcs_file

# Clean and prepare output directory
if {[file exists $output_dir]} {
    file delete -force $output_dir
}
file mkdir $output_dir

# Move output files
file copy -force $bit_file $output_dir/
file copy -force $mcs_file $output_dir/

if {[file exists $ltx_file]} {
  file copy -force $ltx_file $output_dir/  
}


# Delete temp project folder
file delete -force $project_dir

puts "\n << COMPLETED >>"

exit 0