`default_nettype none

module wb_uart_rx
#(
    localparam FIFO_DW = 8,                 // This module is meant for byte-by-byte UART transmisions
    localparam FIFO_AW = 5,
    localparam UART_SHIFTER_WIDTH = 10,
    localparam UART_BITS_SIZE = 4,
    
    `ifdef VERILATOR
    parameter BAUD_DIV_RATE = 3'd05,
    parameter BAUD_DIV_WIDTH = 3
    `else
    parameter BAUD_DIV_RATE = 12'd2604,
    parameter BAUD_DIV_WIDTH = 12
    `endif
)(
    input   wire                            i_reset_n,
    input   wire                            i_clk,

    // Wishbone bus (reduced, neither i_wb_we, i_wb_data and i_wb_addr don't make sense here)
    /* verilator lint_off UNUSED */
    input   wire                            i_wb_cyc,
    /* verilator lint_on UNUSED */
    input   wire                            i_wb_stb,
    output  reg     [FIFO_DW-1:0]           o_wb_data,
    output  reg                             o_wb_ack,
    output  reg                             o_wb_stall,

    // FIFO memory access
    output reg  	[FIFO_AW-1:0]	        o_fifo_mem_addr_w,
	output reg  	[FIFO_AW-1:0]	        o_fifo_mem_addr_r,
	output reg  				            o_fifo_mem_we,
	input  wire  	[FIFO_DW-1:0]	        i_fifo_mem_data_read,
	output reg  	[FIFO_DW-1:0]	        o_fifo_mem_data_write,

    // UART
    input   wire                            uart_rx,
    output  reg                             uart_empty
);

    /******************
     * Components
    ******************/

    // ******** FIFO

    /* verilator lint_off UNUSED */
    wire                            i_fifo_full;
    /* verilator lint_on UNUSED */
    wire                            i_fifo_empty;
    reg                             o_wb_push_fifo_stb;
    reg                             o_wb_push_fifo_cyc;
    reg     [7:0]                   o_wb_push_fifo_data;
    /* verilator lint_off UNUSED */
    wire                            i_wb_push_fifo_ack;
    wire                            i_wb_push_fifo_stall;
    wire                            i_wb_pop_fifo_stall;
    /* verilator lint_on UNUSED */
    reg 				            o_wb_pop_fifo_stb;
	reg 				            o_wb_pop_fifo_cyc;
	wire	[7:0]	                i_wb_pop_fifo_data;
    wire                            i_wb_pop_fifo_ack;
    
    wb_fifo #(.DW(8), .AW(5)) FIFO(
        .i_clk              (i_clk),
        .i_reset_n          (i_reset_n),

        .i_wb_push_data     (o_wb_push_fifo_data),
        .i_wb_push_stb      (o_wb_push_fifo_stb),
        .i_wb_push_cyc      (o_wb_push_fifo_cyc),
        .o_wb_push_stall    (i_wb_push_fifo_stall),
        .o_wb_push_ack      (i_wb_push_fifo_ack),

        .i_wb_pop_stb       (o_wb_pop_fifo_stb),
        .i_wb_pop_cyc       (o_wb_pop_fifo_cyc),
        .o_wb_pop_data      (i_wb_pop_fifo_data),
        .o_wb_pop_stall     (i_wb_pop_fifo_stall),
        .o_wb_pop_ack       (i_wb_pop_fifo_ack),

        .full               (i_fifo_full),
        .empty              (i_fifo_empty),

        .mem_addr_w         (o_fifo_mem_addr_w),
        .mem_addr_r         (o_fifo_mem_addr_r),
        .mem_we             (o_fifo_mem_we),
        .mem_data_read      (i_fifo_mem_data_read),
        .mem_data_write     (o_fifo_mem_data_write)
    );

    // ******** Clock divider
    reg                             o_clk_div_start_stb;
    reg                             o_clk_div_reset_stb;
    wire                            clk_div_did_rise;
    /* verilator lint_off UNUSED */
    wire                            i_clk_div_clk;
    /* verilator lint_on UNUSED */

    clk_divider #(.CLK_DIVIDER_RATE(BAUD_DIV_RATE), .CLK_DIVIDER_WIDTH(BAUD_DIV_WIDTH)) CLK_DIV(
        .i_clk              (i_clk),
        .i_reset_n          (i_reset_n),

        .i_start_stb        (o_clk_div_start_stb),
        .i_reset_stb        (o_clk_div_reset_stb),
        .o_div_clk          (i_clk_div_clk),
        .o_div_clk_rose     (clk_div_did_rise)
    );
    
    /******************
     * DATA PATH
    ******************/
    localparam DATA_ZERO = 8'b0;
    localparam CNT_BITS_ZERO = 4'b0;
    localparam CNT_BITS_FULL = 4'd9;
    localparam UART_SHIFTER_FULL = {UART_SHIFTER_WIDTH{1'b1}};

    // Commands
    reg shift_data;
    reg push_into_fifo;
    reg start_baud_clk_div;
    reg reset_baud_clk_div;

    always @(posedge i_clk) begin
        o_clk_div_start_stb <= start_baud_clk_div;
        o_clk_div_reset_stb <= reset_baud_clk_div;
    end

    // Shift register:
    reg     [UART_SHIFTER_WIDTH-1:0]    shifter_data;
    always @(posedge i_clk) begin
        shifter_data <= shift_data ? { uart_rx, shifter_data[UART_SHIFTER_WIDTH-1:1] } : shifter_data;
    end

    // Output wb signals
    always @(*) begin
        o_wb_stall      = i_wb_pop_fifo_stall;
        o_wb_ack        = i_wb_pop_fifo_ack;
        o_wb_data       = i_wb_pop_fifo_data;
    end

    // Reading data from FIFO and delivering to the user
    always @(*) begin        
        o_wb_pop_fifo_stb       = i_wb_stb && !o_wb_stall;
        o_wb_pop_fifo_cyc       = i_wb_stb && !o_wb_stall;
    end

    // Writing data to FIFO 
    always @(*) begin
        o_wb_push_fifo_stb           = push_into_fifo;
        o_wb_push_fifo_cyc           = push_into_fifo;
        o_wb_push_fifo_data          = shifter_data[UART_SHIFTER_WIDTH-2:1];
    end

    // Empty FIFO signal output
    always @(*) begin
        uart_empty                   = i_fifo_empty;
    end

    /******************
     * FSM (TX side)
    ******************/
    localparam STATE_RX_IDLE                    = 4'd0;
    localparam STATE_RX_PREPARE_DATA            = 4'd1;
    localparam STATE_RX_RECEIVE_BIT0            = 4'd2;
    localparam STATE_RX_RECEIVE_BIT1            = 4'd3;
    localparam STATE_RX_RECEIVE_BIT2            = 4'd4;
    localparam STATE_RX_RECEIVE_BIT3            = 4'd5;
    localparam STATE_RX_RECEIVE_BIT4            = 4'd6;
    localparam STATE_RX_RECEIVE_BIT5            = 4'd7;
    localparam STATE_RX_RECEIVE_BIT6            = 4'd8;
    localparam STATE_RX_RECEIVE_BIT7            = 4'd9;
    localparam STATE_RX_RECEIVE_BIT8            = 4'd10;
    localparam STATE_RX_RECEIVE_BIT9            = 4'd11;
    localparam STATE_RX_PUSH_DATA               = 4'd12;

    reg     [3:0]   state = STATE_RX_IDLE;

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
    reg transition_push_data;
    reg transition_finish_rx;

    always @(*) begin
        transition_prepare_data         = (state == STATE_RX_IDLE) && !uart_rx;     // We start receiving data when rx is 0
        transition_wait_for_bit0        = (state == STATE_RX_PREPARE_DATA);
        transition_wait_for_bit1        = (state == STATE_RX_RECEIVE_BIT0) && clk_div_did_rise;
        transition_wait_for_bit2        = (state == STATE_RX_RECEIVE_BIT1) && clk_div_did_rise;
        transition_wait_for_bit3        = (state == STATE_RX_RECEIVE_BIT2) && clk_div_did_rise;
        transition_wait_for_bit4        = (state == STATE_RX_RECEIVE_BIT3) && clk_div_did_rise;
        transition_wait_for_bit5        = (state == STATE_RX_RECEIVE_BIT4) && clk_div_did_rise;
        transition_wait_for_bit6        = (state == STATE_RX_RECEIVE_BIT5) && clk_div_did_rise;
        transition_wait_for_bit7        = (state == STATE_RX_RECEIVE_BIT6) && clk_div_did_rise;
        transition_wait_for_bit8        = (state == STATE_RX_RECEIVE_BIT7) && clk_div_did_rise;
        transition_wait_for_bit9        = (state == STATE_RX_RECEIVE_BIT8) && clk_div_did_rise;
        transition_push_data            = (state == STATE_RX_RECEIVE_BIT9) && uart_rx;      // We don't wait a full cycle, instead become idle after the stop bit has arrived
        transition_finish_rx            = state == STATE_RX_PUSH_DATA;
    end

    // Applying state transitions
    always @(posedge i_clk) begin
        if (!i_reset_n||state > STATE_RX_PUSH_DATA) begin
            state <= STATE_RX_IDLE;
        end else begin
            if (transition_prepare_data) begin
                state <= STATE_RX_PREPARE_DATA;
            end else if (transition_wait_for_bit0) begin
                state <= STATE_RX_RECEIVE_BIT0;
            end else if (transition_wait_for_bit1) begin
                state <= STATE_RX_RECEIVE_BIT1;
            end else if (transition_wait_for_bit2) begin
                state <= STATE_RX_RECEIVE_BIT2;
            end else if (transition_wait_for_bit3) begin
                state <= STATE_RX_RECEIVE_BIT3;
            end else if (transition_wait_for_bit4) begin
                state <= STATE_RX_RECEIVE_BIT4;
            end else if (transition_wait_for_bit5) begin
                state <= STATE_RX_RECEIVE_BIT5;
            end else if (transition_wait_for_bit6) begin
                state <= STATE_RX_RECEIVE_BIT6;
            end else if (transition_wait_for_bit7) begin
                state <= STATE_RX_RECEIVE_BIT7;
            end else if (transition_wait_for_bit8) begin
                state <= STATE_RX_RECEIVE_BIT8;
            end else if (transition_wait_for_bit9) begin
                state <= STATE_RX_RECEIVE_BIT9;
            end else if (transition_push_data) begin
                state <= STATE_RX_PUSH_DATA;
            end else if (transition_finish_rx) begin
                state <= STATE_RX_IDLE;
            end
        end
    end

    // Control signals for data path
    always @(*) begin
        push_into_fifo              = transition_push_data;
        start_baud_clk_div          = transition_prepare_data;
        shift_data                  = transition_wait_for_bit0||transition_wait_for_bit1||transition_wait_for_bit2||transition_wait_for_bit3||transition_wait_for_bit4||transition_wait_for_bit5||transition_wait_for_bit6||transition_wait_for_bit7||transition_wait_for_bit8||transition_wait_for_bit9;
        reset_baud_clk_div          = transition_finish_rx;
    end

/*********************
* Formal verification
**********************/
`ifdef FORMAL
`ifdef UART_RX
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

    // Assertions

    // Input strobe should be redirected to the FIFO pop strobe
    always @(posedge i_clk)
        if (i_wb_stb && !o_wb_stall)
            assert(o_wb_pop_fifo_cyc && o_wb_pop_fifo_cyc);

    // Input data should match the one we popped from the FIFO
    always @(posedge i_clk)
        if (i_wb_stb && !o_wb_stall)
            assert(o_wb_data == i_wb_pop_fifo_data);

    // We're reading the right bit in each baud clock cycle
    always @(posedge i_clk)
        if (f_past_valid && i_reset_n && $past(i_reset_n && state > STATE_RX_PREPARE_DATA) && state == $past(state - 1'b1)) begin
            assert(shifter_data[UART_SHIFTER_WIDTH-1] == $past(uart_rx));
            assert(shifter_data[UART_SHIFTER_WIDTH-2:0] == $past(shifter_data[UART_SHIFTER_WIDTH-1:1]));
        end

    // While idle, we should check if an UART transmission started
    always @(posedge i_clk)
        if (f_past_valid && i_reset_n && $past(i_reset_n && state == STATE_RX_IDLE && !uart_rx))
            assert(state != STATE_RX_IDLE);

    // When finished receiving data, we should push the received byte:
    always @(posedge i_clk)
        if (f_past_valid && i_reset_n && state == STATE_RX_RECEIVE_BIT9 && uart_rx) begin
            assert(o_wb_push_fifo_stb == 1'b1);
            assert(o_wb_push_fifo_data == shifter_data[UART_SHIFTER_WIDTH-2:1]);
        end

    // Empty signal out
    always @(*)
        assert(uart_empty == i_fifo_empty);
`endif
`endif
    

endmodule