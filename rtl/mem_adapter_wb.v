`default_nettype none
/*
 * mem_adapter_wb
 *
 * Wishbone-based module to provide a memory space to a Z80 computer comprising two memories (ROM and RAM)
 * and some I/O related registers to provide read/write from UART serial port.
 *
 * A separate module that handles the registers and interprets the Z80 signals will use this bus to perform
 * the requested operations.
 *
 * All operations last 1 clock cycle (access to block ram), so memory operations can effectively be dispatched
 * every clock cycle (i.e.: while we're submitting a result from previous operation we can be sending a new one).
 *
 * UART operations are treated like memory accesses. Reads are handled as reading from a FIFO (UART rx module contains one),
 * and writes work in a similar fashion (UART tx module contains another FIFO to handle back pressure).
 * UART status register is accessible at 0xA000 and returns data on the status of both modules (if they're empty or full).
 *
 * Memory map:
 *
 * 0000-3FFF        ROM (code data)
 *
 * 4000-9FFF        RAM (non-code data)
 *
 * A000             UART status register (are tx full/rx empty?)
 * A001             UART access (reading gets a character from UART RX FIFO if any, otherwise returns a 0, writing submits a character to the UART TX FIFO - if full will be eventually ignored)
 * A002             Operation result LED control (writes switch the led to the value of LSB bit, reads are ignored)
 *
 */

module mem_adapter_wb 
#(
    // Total addressable space: 64KB
    parameter Z80_DATA_WIDTH = 8,
    parameter Z80_ADDR_WIDTH = 16,
    // ROM size: 16KB
    parameter ROM_ADDR_WIDTH = 14,
    // RAM size: 24KB?
    parameter RAM_ADDR_WIDTH = 15,
    // Memory map limits
    parameter ROM_ADDR_LIMIT = 16'h4000,
    parameter RAM_ADDR_LIMIT = 16'hA000,
    parameter UART_STATUS_ADDR = 16'hA000,
    parameter UART_ACCESS_ADDR = 16'hA001,
    parameter LED_ADDR = 16'hA002
)(
    input   wire                            i_reset_n,
    input   wire                            i_clk,

    // Wishbone bus 
    input   wire                            i_wb_cyc,
    input   wire                            i_wb_stb,
    input   wire                            i_wb_we,
    input   wire    [Z80_ADDR_WIDTH-1:0]    i_wb_addr,
    input   wire    [Z80_DATA_WIDTH-1:0]    i_wb_data,
    output  reg                             o_wb_ack,
    output  reg                             o_wb_stall,
    output  reg     [Z80_DATA_WIDTH-1:0]    o_wb_data,

    // ROM address bus
    output  reg     [ROM_ADDR_WIDTH-1:0]    o_rom_addr,
    output  reg                             o_rom_stb,
    input   wire    [Z80_DATA_WIDTH-1:0]    i_rom_data,

    // RAM address bus
    output  reg     [RAM_ADDR_WIDTH-1:0]    o_ram_addr,
    output  reg                             o_ram_stb,
    output  reg                             o_ram_wr,
    input   wire    [Z80_DATA_WIDTH-1:0]    i_ram_data,
    output  reg     [Z80_DATA_WIDTH-1:0]    o_ram_data,

    // UART bus
    // Each UART module will support a FIFO memory. We'll treat these as memory read/writes byte by byte.
    output  reg                             o_wb_rx_stb,
    output  reg                             o_wb_rx_cyc,
    input   wire    [Z80_DATA_WIDTH-1:0]    i_wb_rx_data,
    input   wire                            i_wb_rx_stall,
    input   wire                            i_wb_rx_ack,
    input   wire                            rx_empty,

    output  reg                             o_wb_tx_stb,
    output  reg                             o_wb_tx_cyc,
    output  reg     [Z80_DATA_WIDTH-1:0]    o_wb_tx_data,
    input   wire                            i_wb_tx_ack,
    input   wire                            i_wb_tx_stall,

    output  reg                             o_completed_op_led
);

    localparam ROM_DATA_ZERO = {Z80_DATA_WIDTH{1'b0}};
    
    /******************
     * DATA PATH
    ******************/
    reg                             request_rom_data;
    reg                             request_ram_data;
    reg                             request_uart_data_rx;
    reg                             request_uart_data_tx;
    reg                             request_switch_op_led;
    reg                             output_rom_data;
    reg                             output_ram_data;
    reg                             output_uart_data;
    reg                             output_uart_status;
    reg                             output_led_switch;

    reg     [Z80_DATA_WIDTH-1:0]    temp_output_data;
    reg     [Z80_DATA_WIDTH-1:0]    temp_output_uart_data;
    reg     [Z80_DATA_WIDTH-1:0]    temp_output_uart_status;

    // Output data results and acks from memory and UART reads
    always @(*) begin
        temp_output_uart_status = (output_uart_status) ? reg_uart_status : ROM_DATA_ZERO;
        temp_output_uart_data   = (output_uart_data) ? i_wb_rx_data : temp_output_uart_status;
        temp_output_data        = (output_rom_data) ? i_rom_data : temp_output_uart_data;        

        o_wb_data               = (output_ram_data) ? i_ram_data : temp_output_data;
        o_wb_ack                = output_ram_data||output_rom_data||output_uart_data||output_uart_status||output_led_switch;
    end

    // "Operation complete" LED support. Users can write to 0xA002 and the LSB will represent the new state of the LED (1=on). Reads are ignored.
    reg registered_led_value;
    always @(posedge i_clk) begin
        if (!i_reset_n) begin
            registered_led_value <= 1'b0;
        end else begin
            registered_led_value <= (request_switch_op_led) ? i_wb_data[0] : registered_led_value;
        end
    end

    reg temp_led_reset_value;
    always @(*) begin
        o_completed_op_led = registered_led_value;
    end

    always @(*) begin
        // Strobe signals for each memory activates based on the input address from Z80. We should never call both memories at the same time.
        o_rom_stb       = request_rom_data;    
        o_ram_stb       = request_ram_data;
        o_ram_wr        = request_ram_data && i_wb_we;
        o_ram_data      = i_wb_data;

        o_wb_rx_cyc     = request_uart_data_rx||transition_submit_result_uart_rx;
        o_wb_rx_stb     = request_uart_data_rx;

        o_wb_tx_cyc     = request_uart_data_tx||transition_submit_result_uart_tx;
        o_wb_tx_stb     = request_uart_data_tx;
        o_wb_tx_data    = i_wb_data;
    end

    // Address decoding
    reg [Z80_ADDR_WIDTH-1:0] tmp_rom_addr;
    reg [Z80_ADDR_WIDTH-1:0] tmp_ram_addr;
    always @(*) begin
        o_rom_addr      = i_wb_addr[ROM_ADDR_WIDTH-1:0];
        tmp_ram_addr    = i_wb_addr - ROM_ADDR_LIMIT;
        o_ram_addr      = tmp_ram_addr[RAM_ADDR_WIDTH-1:0];
    end

    // UART status register
    //   7   6   5   4   3   2        1              0
    // | x | x | x | x | x | x | tx_fifo_full | rx_fifo_empty |
    reg [Z80_DATA_WIDTH-1:0] reg_uart_status;
    localparam UART_STATUS_REG_GAP = Z80_DATA_WIDTH - 2;

    always @(*) begin
        reg_uart_status = {{UART_STATUS_REG_GAP{1'b0}}, i_wb_tx_stall, rx_empty};
    end

    /******************
     * FSM
    ******************/
    localparam STATE_IDLE                       = 3'd0;
    localparam STATE_WAITING_FOR_ROM            = 3'd1;
    localparam STATE_WAITING_FOR_RAM            = 3'd2;
    localparam STATE_WAITING_FOR_UART_RX        = 3'd3;
    localparam STATE_WAITING_FOR_UART_TX        = 3'd4;
    localparam STATE_WAITING_FOR_UART_STATUS    = 3'd5;
    localparam STATE_WAITING_FOR_LED_SWITCH     = 3'd6;

    reg     [2:0]   state;
    /* verilator lint_off UNOPTFLAT */
    reg     [2:0]   state_next;
    /* verilator lint_on UNOPTFLAT */

    reg transition_wait_for_ram;        
    reg transition_wait_for_rom;        
    reg transition_wait_for_uart_rx;
    reg transition_wait_for_uart_tx;
    reg transition_wait_for_uart_status;
    reg transition_wait_for_led_switch;
    reg transition_submit_result_rom;
    reg transition_submit_result_ram;
    reg transition_submit_result_uart_rx;
    reg transition_submit_result_uart_tx;
    reg transition_submit_result_uart_status;   // Even though we have the data, we introduce a wait cycle to follow the same pace as the other signals
    reg transition_submit_result_led_switch;    // same
    
    // State transitions
    reg received_request;
    reg received_request_ram;
    reg received_request_rom;
    reg received_request_uart_tx;
    reg received_request_uart_rx;
    reg received_request_uart_status_read;
    reg received_request_led_switch;
    reg is_rom_request;
    reg is_ram_request;

    always @(*) begin
        received_request                            = i_wb_stb && i_wb_cyc && !o_wb_stall;
        is_rom_request                              = i_wb_addr < ROM_ADDR_LIMIT;
        is_ram_request                              = i_wb_addr >= ROM_ADDR_LIMIT && i_wb_addr < RAM_ADDR_LIMIT;

        received_request_rom                        = received_request && is_rom_request;
        received_request_ram                        = received_request && is_ram_request;
        received_request_uart_tx                    = received_request && i_wb_addr == UART_ACCESS_ADDR && i_wb_we;
        received_request_uart_rx                    = received_request && i_wb_addr == UART_ACCESS_ADDR && !i_wb_we;
        received_request_uart_status_read           = received_request && i_wb_addr == UART_STATUS_ADDR && !i_wb_we;
        received_request_led_switch                 = received_request && i_wb_addr == LED_ADDR && i_wb_we;

        if (!i_reset_n) begin
            transition_wait_for_rom                 = 1'b0;
            transition_wait_for_ram                 = 1'b0;
            transition_wait_for_uart_rx             = 1'b0;
            transition_wait_for_uart_tx             = 1'b0;
            transition_wait_for_uart_status         = 1'b0;
            transition_wait_for_led_switch          = 1'b0;
            transition_submit_result_rom            = 1'b0;
            transition_submit_result_ram            = 1'b0;
            transition_submit_result_uart_rx        = 1'b0;
            transition_submit_result_uart_tx        = 1'b0;
            transition_submit_result_uart_status    = 1'b0;
            transition_submit_result_led_switch     = 1'b0;
        end else begin
            transition_wait_for_rom                 = state == STATE_IDLE && i_reset_n && received_request_rom;
            transition_wait_for_ram                 = state == STATE_IDLE && i_reset_n && received_request_ram;
            transition_wait_for_uart_rx             = state == STATE_IDLE && i_reset_n && received_request_uart_rx;
            transition_wait_for_uart_tx             = state == STATE_IDLE && i_reset_n && received_request_uart_tx;
            transition_wait_for_uart_status         = state == STATE_IDLE && i_reset_n && received_request_uart_status_read;
            transition_wait_for_led_switch          = state == STATE_IDLE && i_reset_n && received_request_led_switch;
            transition_submit_result_rom            = state == STATE_WAITING_FOR_ROM && i_reset_n;
            transition_submit_result_ram            = state == STATE_WAITING_FOR_RAM && i_reset_n;
            transition_submit_result_uart_rx        = state == STATE_WAITING_FOR_UART_RX && i_reset_n;
            transition_submit_result_uart_tx        = state == STATE_WAITING_FOR_UART_TX && i_reset_n;
            transition_submit_result_uart_status    = state == STATE_WAITING_FOR_UART_STATUS && i_reset_n;
            transition_submit_result_led_switch     = state == STATE_WAITING_FOR_LED_SWITCH && i_reset_n;
        end        
    end

    // Applying state transitions
    always @(*) begin
        if (!i_reset_n) begin
            state_next = STATE_IDLE;
        end else begin
            // Avoid illegal states:
            state_next = (state > STATE_WAITING_FOR_LED_SWITCH) ? STATE_IDLE : state_next;

            state_next = (transition_wait_for_rom)              ? STATE_WAITING_FOR_ROM : state_next;
            state_next = (transition_wait_for_ram)              ? STATE_WAITING_FOR_RAM : state_next;
            state_next = (transition_wait_for_uart_rx)          ? STATE_WAITING_FOR_UART_RX : state_next;
            state_next = (transition_wait_for_uart_tx)          ? STATE_WAITING_FOR_UART_TX : state_next;
            state_next = (transition_wait_for_uart_status)      ? STATE_WAITING_FOR_UART_STATUS : state_next;
            state_next = (transition_wait_for_led_switch)       ? STATE_WAITING_FOR_LED_SWITCH : state_next;
            state_next = (transition_submit_result_rom)         ? STATE_IDLE : state_next;
            state_next = (transition_submit_result_ram)         ? STATE_IDLE : state_next;
            state_next = (transition_submit_result_uart_rx)     ? STATE_IDLE : state_next;
            state_next = (transition_submit_result_uart_tx)     ? STATE_IDLE : state_next;
            state_next = (transition_submit_result_uart_status) ? STATE_IDLE : state_next;
            state_next = (transition_submit_result_led_switch)  ? STATE_IDLE : state_next;
        end
    end

    always @(posedge i_clk) begin
        if (!i_reset_n) begin
            state <= STATE_IDLE;
        end else begin
            state <= state_next;
        end        
    end

    // Control signals for data path
    always @(*) begin
        request_rom_data            = transition_wait_for_rom;
        request_ram_data            = transition_wait_for_ram;
        request_uart_data_rx        = transition_wait_for_uart_rx;
        request_uart_data_tx        = transition_wait_for_uart_tx;
        request_switch_op_led       = transition_wait_for_led_switch;
        output_rom_data             = transition_submit_result_rom;
        output_ram_data             = transition_submit_result_ram;
        output_uart_data            = transition_submit_result_uart_rx;
        output_uart_status          = transition_submit_result_uart_status;
        output_led_switch           = transition_submit_result_led_switch;
    end

    always @(*) begin
        o_wb_stall = 1'b0; // It doesn't look like we ever stall (if block ram works as we expect)
    end


/*********************
* Formal verification
**********************/
`ifdef	FORMAL
	reg f_past_valid;
	initial f_past_valid = 0;

	always @(posedge i_clk) begin
		f_past_valid <= 1'b1;
	end

    // The bus initializes without requests
    initial assume(!i_reset_n);
    initial assume(!i_wb_cyc);
    initial assume(!i_wb_stb);

    // STB and CYC are tied
    always @(*)
		if (i_wb_stb)
			assume(i_wb_cyc);

    // Strobe signals are 1-cycle long
    always @(posedge i_clk) begin
        if (f_past_valid && $past(i_wb_stb))
            assume(!i_wb_stb);
    end

    // Check the state after a reset
    always @(posedge i_clk) begin
        if (f_past_valid && $past(!i_reset_n)) begin
            assert(!o_wb_ack && !o_wb_stall && o_wb_data == ROM_DATA_ZERO);
        end
    end

    // Check that we ack after a request
    reg f_had_memory_access;
    reg f_had_uart_status_access;
    reg f_had_uart_request;
    reg f_had_led_switch_request;
    reg f_had_actual_request;

    always @(*) begin
        f_had_memory_access = i_wb_addr < UART_STATUS_ADDR;
        f_had_uart_status_access = i_wb_addr == UART_STATUS_ADDR && !i_wb_we;
        f_had_uart_request = i_wb_addr == UART_ACCESS_ADDR && !i_wb_we;
        f_had_led_switch_request = i_wb_addr == LED_ADDR && i_wb_we;

        f_had_actual_request = i_wb_stb && (f_had_memory_access||f_had_uart_status_access||f_had_uart_request||f_had_led_switch_request);
    end

    always @(posedge i_clk) begin
        if (f_past_valid && $past(i_reset_n) && i_reset_n && $past(f_had_actual_request)) begin
            assert(o_wb_ack);
        end
    end

    // ACK line can't be high if there's no on-going request
    always @(posedge i_clk) begin        
        if (f_past_valid && $past(!i_wb_cyc)) begin
            assert(!o_wb_ack);
        end
    end

    // ACK signal should last 1 cycle
    always @(posedge i_clk) begin
        if (f_past_valid && $past(i_reset_n) && i_reset_n && $past(o_wb_ack)) begin
            assert(!o_wb_ack);
        end
    end

    // We should be able to accept a request 1 cycle after an ACK
    always @(posedge i_clk) begin
        if (f_past_valid && $past(i_reset_n, 2) && $past(i_reset_n) && i_reset_n && $past(o_wb_ack, 2) && $past(f_had_actual_request)) begin
            assert(state != STATE_IDLE);
        end
    end

    // Stall line is never occupied (for our current component there's no back pressure in place)
    always @(posedge i_clk) begin        
        assert(!o_wb_stall);
    end

    // ROM requests should be passed to the appropiate memory bank
    always @(posedge i_clk) begin
        if (f_past_valid && $past(i_reset_n) && i_reset_n && i_wb_stb && i_wb_addr < ROM_ADDR_LIMIT) begin
            assert(o_rom_addr == i_wb_addr);
            assert(o_rom_stb == 1'b1);
        end
    end
    
    // RAM requests should be passed to the appropiate memory bank
    always @(posedge i_clk) begin
        if (f_past_valid && $past(i_reset_n) && i_reset_n && i_wb_stb && i_wb_addr >= ROM_ADDR_LIMIT && i_wb_addr < RAM_ADDR_LIMIT) begin
            assert(o_ram_addr == i_wb_addr - ROM_ADDR_LIMIT);
            assert(o_ram_stb == 1'b1);
            assert(o_ram_wr == i_wb_we);
            assert(o_ram_data == i_wb_data);
        end
    end

    // We should output the UART status register when requested
    always @(posedge i_clk) begin
        if (f_past_valid && $past(i_reset_n) && i_reset_n && $past(i_wb_stb && i_wb_addr == UART_STATUS_ADDR && !i_wb_we)) begin
            assert(o_wb_data == reg_uart_status);
        end
    end

    // UART status register should have the intended values:
    always @(*) begin
        assert(reg_uart_status == {6'b0, i_wb_tx_stall, rx_empty});
    end

    // We should generate a request to the UART RX module when requested
    always @(posedge i_clk) begin
        if (f_past_valid && $past(i_reset_n) && i_reset_n && i_wb_stb && i_wb_addr == UART_ACCESS_ADDR && !i_wb_we) begin
            assert(o_wb_rx_cyc == 1'b1);
            assert(o_wb_rx_stb == 1'b1);
        end
    end

    // We should generate a request to the UART TX module when requested
    always @(posedge i_clk) begin
        if (f_past_valid && $past(i_reset_n) && i_reset_n && i_wb_stb && i_wb_addr == UART_ACCESS_ADDR && i_wb_we) begin
            assert(o_wb_tx_cyc == 1'b1);
            assert(o_wb_tx_stb == 1'b1);
            assert(o_wb_tx_data == i_wb_data);
        end
    end

    // We shouldn't have multiple kind of requests (RAM, ROM, UART...) sent at the same time
    always @(posedge i_clk) begin
        if (f_past_valid && i_reset_n) begin
            assert(!(o_ram_stb && o_rom_stb));
            assert(!(o_ram_stb && o_wb_rx_stb));
            assert(!(o_rom_stb && o_wb_rx_stb));
            assert(!(o_ram_stb && o_wb_tx_stb));
            assert(!(o_rom_stb && o_wb_tx_stb));
            assert(!(o_wb_tx_stb && o_wb_rx_stb));
        end
    end

    // ROM results should be returned
    always @(posedge i_clk) begin
        if (f_past_valid && $past(i_reset_n) && i_reset_n && $past(i_wb_stb) && $past(i_wb_addr < ROM_ADDR_LIMIT)) begin
            assert(o_wb_data == i_rom_data);
        end
    end

    // RAM results should be returned
    always @(posedge i_clk) begin
        if (f_past_valid && $past(i_reset_n) && i_reset_n && $past(i_wb_stb) && $past(i_wb_addr >= ROM_ADDR_LIMIT && i_wb_addr < RAM_ADDR_LIMIT)) begin
            assert(o_wb_data == i_ram_data);
        end
    end

    // UART RX results should be returned
    always @(posedge i_clk) begin
        if (f_past_valid && $past(i_reset_n) && i_reset_n && $past(i_wb_stb && i_wb_addr == UART_ACCESS_ADDR && !i_wb_we)) begin
            assert(o_wb_data == i_wb_rx_data);
        end
    end

    // LED should be switched when requested
    always @(posedge i_clk) begin
        if (f_past_valid && $past(i_reset_n) && i_reset_n && $past(i_wb_stb && i_wb_addr == LED_ADDR && i_wb_we)) begin
            assert(o_completed_op_led == $past(i_wb_data[0]));
        end
    end

    // I/O requests aren't performed if there's no request in place (without resets)
    always @(posedge i_clk) begin
        if (f_past_valid && $past(i_reset_n) && i_reset_n && !i_wb_cyc) begin
            assert(!o_rom_stb);
            assert(!o_ram_stb);
            assert(!o_wb_rx_stb);
            assert(!o_wb_tx_stb);
        end
    end
`endif

endmodule