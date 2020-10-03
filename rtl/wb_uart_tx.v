`default_nettype none

module wb_uart_tx
#(
    localparam FIFO_DW = 8,                 // This module is meant for byte-by-byte UART transmisions
    localparam FIFO_AW = 5,
    localparam UART_SHIFTER_WIDTH = 10,
    localparam UART_BITS_SIZE = 4
)(
    input   wire                            i_reset_n,
    input   wire                            i_clk,

    // Wishbone bus (reduced, neither i_wb_we nor i_wb_addr makes sense here)
    /* verilator lint_off UNUSED */
    input   wire                            i_wb_cyc,
    /* verilator lint_on UNUSED */
    input   wire                            i_wb_stb,
    input   wire    [FIFO_DW-1:0]           i_wb_data,
    output  reg                             o_wb_ack,
    output  reg                             o_wb_stall,

    // FIFO write interface
    output  reg                             o_wb_push_fifo_stb,
    output  reg                             o_wb_push_fifo_cyc,
    output  reg     [FIFO_DW-1:0]           o_wb_push_fifo_data,
    input   wire                            i_wb_push_fifo_ack,
    input   wire                            i_wb_push_fifo_stall,

    // FIFO read interface
    output	reg 				            o_wb_pop_fifo_stb,
	output	reg 				            o_wb_pop_fifo_cyc,
	input   wire	[FIFO_DW-1:0]	        i_wb_pop_fifo_data,
    input   wire                            i_wb_pop_fifo_ack,

    input   wire                            i_fifo_empty,

    // Clock divider for bauds
    output  reg                             o_clk_div_start_stb,
    output  reg                             o_clk_div_reset_stb,
    input   wire                            i_clk_div_clk,

    // Shifter
    /* verilator lint_off UNOPT */
    output  reg     [UART_SHIFTER_WIDTH-1:0]    o_shifter_data,
    /* verilator lint_on UNOPT */
    output  reg     [2:0]                       o_shifter_op,
    input   wire    [UART_SHIFTER_WIDTH-1:0]    i_shifter_data,

    // UART
    output  reg                             uart_tx
);

    /******************
     * DATA PATH
    ******************/
    localparam DATA_ZERO = 8'b0;
    localparam CNT_BITS_ZERO = 4'b0;
    localparam CNT_BITS_FULL = 4'd9;
    localparam UART_SHIFTER_FULL = {UART_SHIFTER_WIDTH{1'b1}};

    // Commands
    reg load_shift_data;
    reg shift_data;
    reg clear_shifted_data;
    reg load_from_fifo;
    reg start_baud_clk_div;
    reg reset_baud_clk_div;

    // Clock divider
    reg     [1:0]   clk_div_rise_shift;
    reg             clk_div_did_rise;

    always @(posedge i_clk) begin
        clk_div_rise_shift <= {clk_div_rise_shift[0], i_clk_div_clk};
    end

    always @(*) begin
        clk_div_did_rise    = clk_div_rise_shift == 2'b01;
    end

    always @(posedge i_clk) begin
        o_clk_div_start_stb <= start_baud_clk_div;
        o_clk_div_reset_stb <= reset_baud_clk_div;
    end

    // Shift register
    reg     [UART_SHIFTER_WIDTH-1:0]    temp_shifter_data_clear;
    reg     [UART_SHIFTER_WIDTH-1:0]    temp_shifter_data_load;
    always @(*) begin
        temp_shifter_data_clear     = clear_shifted_data ? UART_SHIFTER_FULL : o_shifter_data;
        temp_shifter_data_load      = load_shift_data ? {1'b1, i_wb_pop_fifo_data, 1'b0} : temp_shifter_data_clear;
        o_shifter_data              = shift_data ? i_shifter_data : temp_shifter_data_load;
        o_shifter_op                = 3'd3; // shift right with 1 padding
    end

    always @(*) begin
        uart_tx = (i_reset_n && state >= STATE_TX_SEND_BIT0) ? i_shifter_data[0] : 1'b1;
    end

    // Output wb signals
    always @(*) begin
        o_wb_stall      = i_wb_push_fifo_stall;
        o_wb_ack        = i_wb_push_fifo_ack;
    end

    // Sending user data to FIFO
    always @(*) begin        
        o_wb_push_fifo_stb       = i_wb_stb && !o_wb_stall;
        o_wb_push_fifo_cyc       = i_wb_stb && !o_wb_stall;
        o_wb_push_fifo_data      = i_wb_data;
    end

    // Getting data from FIFO 
    always @(posedge i_clk) begin
        o_wb_pop_fifo_stb           <= load_from_fifo;
        o_wb_pop_fifo_cyc           <= load_from_fifo;
    end

    /******************
     * FSM (TX side)
    ******************/
    localparam STATE_TX_IDLE                    = 4'd0;
    localparam STATE_TX_WAIT_FOR_FIFO_ACK       = 4'd1;
    localparam STATE_TX_PREPARE_DATA            = 4'd2;
    localparam STATE_TX_SEND_BIT0               = 4'd3;
    localparam STATE_TX_SEND_BIT1               = 4'd4;
    localparam STATE_TX_SEND_BIT2               = 4'd5;
    localparam STATE_TX_SEND_BIT3               = 4'd6;
    localparam STATE_TX_SEND_BIT4               = 4'd7;
    localparam STATE_TX_SEND_BIT5               = 4'd8;
    localparam STATE_TX_SEND_BIT6               = 4'd9;
    localparam STATE_TX_SEND_BIT7               = 4'd10;
    localparam STATE_TX_SEND_BIT8               = 4'd11;
    localparam STATE_TX_SEND_BIT9               = 4'd12;

    reg     [3:0]   state;
    /* verilator lint_off UNOPTFLAT */
    reg     [3:0]   state_next;
    /* verilator lint_on UNOPTFLAT */

    reg transition_wait_for_fifo_read;
    reg transition_prepare_data;
    reg transition_wait_for_bit0;
    reg transition_wait_for_bit1;
    reg transition_wait_for_bit2;
    reg transition_wait_for_bit3;
    reg transition_wait_for_bit4;
    reg transition_wait_for_bit5;
    reg transition_wait_for_bit6;
    reg transition_wait_for_bit7;
    reg transition_wait_for_bit8;
    reg transition_wait_for_bit9;
    reg transition_finish_tx;

    always @(*) begin
        transition_wait_for_fifo_read   = (state == STATE_TX_IDLE) && !i_fifo_empty;
        transition_prepare_data         = (state == STATE_TX_WAIT_FOR_FIFO_ACK) && i_wb_pop_fifo_ack;
        transition_wait_for_bit0        = (state == STATE_TX_PREPARE_DATA);
        transition_wait_for_bit1        = (state == STATE_TX_SEND_BIT0) && clk_div_did_rise;
        transition_wait_for_bit2        = (state == STATE_TX_SEND_BIT1) && clk_div_did_rise;
        transition_wait_for_bit3        = (state == STATE_TX_SEND_BIT2) && clk_div_did_rise;
        transition_wait_for_bit4        = (state == STATE_TX_SEND_BIT3) && clk_div_did_rise;
        transition_wait_for_bit5        = (state == STATE_TX_SEND_BIT4) && clk_div_did_rise;
        transition_wait_for_bit6        = (state == STATE_TX_SEND_BIT5) && clk_div_did_rise;
        transition_wait_for_bit7        = (state == STATE_TX_SEND_BIT6) && clk_div_did_rise;
        transition_wait_for_bit8        = (state == STATE_TX_SEND_BIT7) && clk_div_did_rise;
        transition_wait_for_bit9        = (state == STATE_TX_SEND_BIT8) && clk_div_did_rise;
        transition_finish_tx            = (state == STATE_TX_SEND_BIT9) && clk_div_did_rise;
    end

    // Applying state transitions
    always @(*) begin
        if (!i_reset_n) begin
            state_next = STATE_TX_IDLE;
        end else begin
            // Avoid illegal states:
            state_next = (state > STATE_TX_SEND_BIT9)           ? STATE_TX_IDLE : state_next;

            state_next = (transition_wait_for_fifo_read)        ? STATE_TX_WAIT_FOR_FIFO_ACK : state_next;
            state_next = (transition_prepare_data)              ? STATE_TX_PREPARE_DATA : state_next;
            state_next = (transition_wait_for_bit0)             ? STATE_TX_SEND_BIT0 : state_next;
            state_next = (transition_wait_for_bit1)             ? STATE_TX_SEND_BIT1 : state_next;
            state_next = (transition_wait_for_bit2)             ? STATE_TX_SEND_BIT2 : state_next;
            state_next = (transition_wait_for_bit3)             ? STATE_TX_SEND_BIT3 : state_next;
            state_next = (transition_wait_for_bit4)             ? STATE_TX_SEND_BIT4 : state_next;
            state_next = (transition_wait_for_bit5)             ? STATE_TX_SEND_BIT5 : state_next;
            state_next = (transition_wait_for_bit6)             ? STATE_TX_SEND_BIT6 : state_next;
            state_next = (transition_wait_for_bit7)             ? STATE_TX_SEND_BIT7 : state_next;
            state_next = (transition_wait_for_bit8)             ? STATE_TX_SEND_BIT8 : state_next;
            state_next = (transition_wait_for_bit9)             ? STATE_TX_SEND_BIT9 : state_next;
            state_next = (transition_finish_tx)                 ? STATE_TX_IDLE : state_next;
        end
    end

    always @(posedge i_clk) begin
        if (!i_reset_n) begin
            state <= STATE_TX_IDLE;
        end else begin
            state <= state_next;
        end        
    end

    // Control signals for data path
    always @(*) begin
        load_from_fifo              = transition_wait_for_fifo_read;
        start_baud_clk_div          = transition_prepare_data;
        load_shift_data             = transition_prepare_data;
        shift_data                  = transition_wait_for_bit1||transition_wait_for_bit2||transition_wait_for_bit3||transition_wait_for_bit4||transition_wait_for_bit5||transition_wait_for_bit6||transition_wait_for_bit7||transition_wait_for_bit8||transition_wait_for_bit9;
        clear_shifted_data          = transition_finish_tx;
        reset_baud_clk_div          = transition_finish_tx;
    end

/*********************
* Formal verification
**********************/
`ifdef FORMAL
`ifdef UART_TX
	reg f_past_valid;
	initial f_past_valid = 0;

	always @(posedge i_clk) begin
		f_past_valid <= 1'b1;
	end

    // Assumptions
    initial assume(!i_reset_n);

    // STB and CYC are tied
    always @(*)
		if (i_wb_stb)
			assume(i_wb_cyc);

    // Strobe signals are 1-cycle long
    always @(posedge i_clk)
        if (f_past_valid && $past(i_wb_stb))
            assume(!i_wb_stb);

    // Inputs from shift register are stable if we don't perform a change to its outputs
    always @(posedge i_clk)
        if (f_past_valid && $stable(o_shifter_data && o_shifter_op))
            assume($stable(i_shifter_data));

    // Assertions

    // Input strobe should be redirected to the FIFO push strobe
    always @(posedge i_clk)
        if (i_wb_stb && !o_wb_stall)
            assert(o_wb_push_fifo_cyc && o_wb_push_fifo_cyc);

    // Input data should match the one we push to the FIFO
    always @(posedge i_clk)
        if (i_wb_stb && !o_wb_stall)
            assert(i_wb_data == o_wb_push_fifo_data);

    // We're sending the right bit in each baud clock cycle
    always @(posedge i_clk)
        if (f_past_valid && i_reset_n && state == STATE_TX_SEND_BIT0)
            assert(uart_tx == i_shifter_data[0]);

    // We should shift the bit after a baud clock change on the rising edge
    always @(posedge i_clk)
        if (f_past_valid && i_reset_n && $past(!i_clk_div_clk, 2) && $past(i_clk_div_clk) && state > STATE_TX_PREPARE_DATA && state < STATE_TX_SEND_BIT9)
            assert(o_shifter_data == i_shifter_data && o_shifter_op == 3'd3);

    // While idle, the TX line should be held inactive (= 1'b1)
    always @(*)
        if (state == STATE_TX_IDLE)
            assert(uart_tx == 1'b1);

    // While idle, we should check if the FIFO is not empty, and in that case start sending another byte
    always @(posedge i_clk)
        if (i_reset_n && state == STATE_TX_IDLE && !i_fifo_empty)
            assert(o_wb_pop_fifo_stb);
`endif
`endif

endmodule