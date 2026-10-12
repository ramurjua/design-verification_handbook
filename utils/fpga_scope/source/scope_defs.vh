/* Shared constants for the fpga_scope core. See docs/protocol.md for the wire format. */

/* Frame sync bytes */
localparam [7:0] SCOPE_SYNC_HOST = 8'hAA; /* host -> device */
localparam [7:0] SCOPE_SYNC_DEV  = 8'h55; /* device -> host */

/* Opcodes */
localparam [7:0] SCOPE_CMD_GET_INFO     = 8'h01;
localparam [7:0] SCOPE_CMD_SET_TRIGGER  = 8'h02;
localparam [7:0] SCOPE_CMD_ARM          = 8'h03;
localparam [7:0] SCOPE_CMD_GET_STATUS   = 8'h04;
localparam [7:0] SCOPE_CMD_DUMP         = 8'h05;
localparam [7:0] SCOPE_CMD_ABORT        = 8'h06;
localparam [7:0] SCOPE_CMD_SET_MODE     = 8'h07;
localparam [7:0] SCOPE_CMD_STREAM_START = 8'h08; /* payload: 4 B sample_count; CMD_ABORT (0x06) cancels an in-flight burst */
localparam [7:0] SCOPE_CMD_CONTROL_WRITE = 8'h09; /* payload: 1 B control index, 4 B value */
localparam [7:0] SCOPE_CMD_CONTROL_READ  = 8'h0A; /* payload: 1 B control index; reply: index, 4 B value */

/* Status codes */
localparam [7:0] SCOPE_STATUS_OK       = 8'h00;
localparam [7:0] SCOPE_STATUS_ERROR    = 8'h01;

/* Operating modes, selected at runtime via CMD_SET_MODE (both always built in) */
localparam [0:0] SCOPE_MODE_SCOPE  = 1'd0; /* ring-buffer capture + trigger */
localparam [0:0] SCOPE_MODE_STREAM = 1'd1; /* continuous live sample streaming, no buffering */

localparam SCOPE_MODES_MASK_SCOPE  = 8'b0000_0001;
localparam SCOPE_MODES_MASK_STREAM = 8'b0000_0010;

/* Capture FSM states (also used verbatim as the GET_STATUS state byte in SCOPE_MODE_SCOPE) */
localparam [1:0] SCOPE_ST_IDLE      = 2'd0;
localparam [1:0] SCOPE_ST_ARMED     = 2'd1;
localparam [1:0] SCOPE_ST_CAPTURING = 2'd2;
localparam [1:0] SCOPE_ST_DONE      = 2'd3;

/* Streamer states (GET_STATUS state byte in SCOPE_MODE_STREAM) */
localparam [1:0] SCOPE_ST_STREAM_IDLE    = 2'd0;
localparam [1:0] SCOPE_ST_STREAM_RUNNING = 2'd1;

/* Trigger channel_cfg[i] bit layout */
localparam SCOPE_TRIG_EN_BIT     = 7;
localparam SCOPE_TRIG_TYPE_LSB   = 4; /* 2 bits: 00 level-low, 01 level-high, 10 edge-rising, 11 edge-falling */
localparam SCOPE_TRIG_BITSEL_LSB = 0; /* 3 bits */

localparam [1:0] SCOPE_TRIG_TYPE_LEVEL_LOW  = 2'b00;
localparam [1:0] SCOPE_TRIG_TYPE_LEVEL_HIGH = 2'b01;
localparam [1:0] SCOPE_TRIG_TYPE_EDGE_RISE  = 2'b10;
localparam [1:0] SCOPE_TRIG_TYPE_EDGE_FALL  = 2'b11;

/* Controls: 32-bit registers the host writes, always all of them (no parameter) */
localparam SCOPE_NUM_CONTROLS = 8;

localparam SCOPE_PROTOCOL_VERSION = 8'h02; /* 0x01: no controls */
