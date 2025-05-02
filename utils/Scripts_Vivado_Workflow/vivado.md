# 📦 Scripts Vivado Workflow

This project includes a TCL + BAT based scripts for automation flow for creating, synthesizing, implementing, and generating the bitstream, memory configuration file and debug probes using Xilinx Vivado.

## 🛠 Requirements

- Installed Vivado 2022.1  (or other compatible version)
- Folder structure as follows: 

project-root/
├── constraints/
│ └── xdc_file.xdc
├── source/
│ └── *.v / *.sv / *.vhd
├── memory_files/
│ └── *.mem
├── include/
│ └── *.vh
├── scripts/
│ ├── build_project.tcl
│ └── make.bat
└── output/

## ⚙ Configuration

Inside .bat file the Vivado installation root should be configured.

```bash
set VIVADO_PATH=D:\Xilinx\Vivado\2022.1
```

Inside .tcl file project settings sholud be configured. 

```bash
set project_name        PROJECT_NAME
set part_name           xc7a75tlfgg484-2L         ;
set mem_part            mx25l12872f-spi-x1_x2_x4  ;
set top_name            top
set xdc_file            xdc_file
set output_dir          ../output
set project_dir         ../project/autogen
``` 

If some of the following types of files are not present in the project, its corresponding line should be commented.

```bash
# Add source files
add_files [ glob ../source/*.v]
add_files [ glob ../source/*.sv]
add_files [ glob ../source/*.vhd]

# Add include files
add_files [ glob ../include/*.vh]

# Add memory files
add_files [ glob ../memory_files/*.mem]
```

## 🚀 Ejecución

From powershell or cmd, inside scripts folder execute:

```bash
.\make.bat
```