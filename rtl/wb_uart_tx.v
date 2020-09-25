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
    input   wire                            i_wb_cyc,
    input   wire                            i_wb_stb,
    input   wire    [FIFO_DW-1:0]           i_wb_data,
    output  reg                             o_wb_ack,
    output  reg                             o_wb_stall,

    // FIFO interface
    output  reg                             o_wb_fifo_stb,
    output  reg                             o_wb_fifo_cyc,
    output  reg     [FIFO_DW-1:0]           o_wb_fifo_data,
    output  reg                             o_wb_we,
    input   wire                            i_wb_fifo_ack,
    input   wire                            i_wb_fifo_stall,
    input   wire    [FIFO_DW-1:0]           i_wb_fifo_data,
    input   wire                            i_fifo_empty,

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
    reg update_bit_counter;
    reg clear_bit_counter;
    reg load_shift_data;
    reg shift_data;
    reg clear_shifted_data;

    reg                             is_request_active;
    reg                             clock_divider_change;
    /* verilator lint_off UNOPTFLAT */
    reg     [UART_BITS_SIZE-1:0]    cnt_bits;
    /* verilator lint_on UNOPTFLAT */

    // Bit counter
    reg     [UART_BITS_SIZE-1:0]    temp_cnt_bits_reset;
    reg     [UART_BITS_SIZE-1:0]    cnt_bits_next;
    always @(*) begin
        temp_cnt_bits_reset     = (!i_reset_n||clear_bit_counter) ? CNT_BITS_FULL : cnt_bits;
        cnt_bits_next           = (cnt_bits == CNT_BITS_ZERO) ? CNT_BITS_FULL : cnt_bits - 1'b1;

        cnt_bits                = (update_bit_counter) ? cnt_bits_next : temp_cnt_bits_reset;
    end

    // TODO: Clock divider


    // Bit shifter / UART TX signal
    /* verilator lint_off UNOPTFLAT */
    reg     [UART_SHIFTER_WIDTH-1:0]    i_shifter_data;
    /* verilator lint_on UNOPTFLAT */
    wire    [UART_SHIFTER_WIDTH-1:0]    o_shifter_data;
    shifter #(.DATA_WIDTH(10)) SHIFTER (
        .i_data         (i_shifter_data),
        .i_op           (3'd3),             // Shift right padding with 1'b1
        .o_data         (o_shifter_data)
    );

    reg     [UART_SHIFTER_WIDTH-1:0]    temp_shifter_data_clear;
    reg     [UART_SHIFTER_WIDTH-1:0]    temp_shifter_data_load;
    always @(*) begin
        temp_shifter_data_clear     = clear_shifted_data ? UART_SHIFTER_FULL : i_shifter_data;
        temp_shifter_data_load      = load_shift_data ? {1'b1, i_wb_data, 1'b0} : temp_shifter_data_clear;
        i_shifter_data              = shift_data ? o_shifter_data : temp_shifter_data_load;
    end

    always @(*) begin
        uart_tx = o_shifter_data[0];
    end

    // Output wb signals
    always @(*) begin
        o_wb_stall      = i_wb_fifo_stall;
        o_wb_ack        = i_wb_fifo_ack;
    end

    // Splitting signals from user interface and TX side
    reg                     tx_o_fifo_stb;
    reg                     tx_o_fifo_cyc;
    reg     [FIFO_DW-1:0]   tx_o_fifo_data;

    always @(*) begin        
        o_wb_fifo_stb       = is_request_active ? i_wb_stb : tx_o_fifo_stb;
        o_wb_fifo_cyc       = is_request_active ? i_wb_stb : tx_o_fifo_stb;     // TODO: fulfill to next state
        o_wb_fifo_data      = is_request_active ? i_wb_data : DATA_ZERO;
        o_wb_we             = is_request_active;
    end

    /******************
     * FSM (TX side)
    ******************/
    localparam STATE_TX_IDLE                    = 2'd0;
    localparam STATE_TX_WAIT_FOR_FIFO_ACK       = 2'd1;
    localparam STATE_TX_WAIT_BIT_SHIFT          = 2'd2;
    localparam STATE_TX_UPDATE_BIT_COUNTER      = 2'd3;

    reg     [1:0]   state;
    /* verilator lint_off UNOPTFLAT */
    reg     [1:0]   state_next;
    /* verilator lint_on UNOPTFLAT */
    
    reg transition_wait_for_fifo_read;
    reg transition_wait_for_bit_shift;
    reg transition_update_bit_counter;
    reg transition_send_next_bit;
    reg transition_finish_tx;

    always @(*) begin
        transition_wait_for_fifo_read   = (state == STATE_TX_IDLE) && !is_request_active && !i_fifo_empty;
        transition_wait_for_bit_shift   = (state == STATE_TX_WAIT_FOR_FIFO_ACK) && i_wb_fifo_ack;
        transition_update_bit_counter   = (state == STATE_TX_WAIT_BIT_SHIFT) && clock_divider_change;
        transition_send_next_bit        = (state == STATE_TX_UPDATE_BIT_COUNTER) && cnt_bits > CNT_BITS_ZERO;
        transition_finish_tx            = (state == STATE_TX_UPDATE_BIT_COUNTER) && cnt_bits == CNT_BITS_ZERO;
    end

    // Applying state transitions
    always @(*) begin
        if (!i_reset_n) begin
            state_next = STATE_TX_IDLE;
        end else begin
            // Avoid illegal states:
            state_next = (state > STATE_TX_WAIT_BIT_SHIFT) ? STATE_TX_IDLE : state_next;

            state_next = (transition_wait_for_fifo_read)        ? STATE_TX_WAIT_FOR_FIFO_ACK : state_next;
            state_next = (transition_wait_for_bit_shift)        ? STATE_TX_WAIT_BIT_SHIFT : state_next;
            state_next = (transition_update_bit_counter)        ? STATE_TX_UPDATE_BIT_COUNTER : state_next;
            state_next = (transition_send_next_bit)             ? STATE_TX_WAIT_BIT_SHIFT : state_next;
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
        update_bit_counter          = transition_update_bit_counter;
        load_shift_data             = transition_wait_for_bit_shift;
        clear_bit_counter           = transition_finish_tx;
        shift_data                  = transition_send_next_bit;
        clear_shifted_data          = transition_finish_tx;
    end

endmodule