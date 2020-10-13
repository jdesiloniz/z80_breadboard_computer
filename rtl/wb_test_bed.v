/*
 * wb_test_bed
 *
 * Wishbone-based module to provide a test bed for an existing CPU. Offers connections to a memory adapter
 * that provides access to memory (ROM and RAM) and some peripherals (UART serial port and an output LED).
 *
 * Users require to provide memory access for two UART FIFOs (32 bytes/byte-wide, expected BRAM) and
 * also memory access for ROM and RAM (through simplified wishbone-like ports).
 * 
 * See description and memory mapping for those peripherals and extra info in `wb_mem_adapter` module.
 *
*/

module wb_test_bed
#(
    // Memory adapter
    parameter CPU_DATA_WIDTH = 8,
    parameter CPU_ADDR_WIDTH = 16,
    parameter ROM_ADDR_WIDTH = 14,
    parameter RAM_ADDR_WIDTH = 15,
    parameter ROM_ADDR_LIMIT = 16'h4000,
    parameter RAM_ADDR_LIMIT = 16'hA000,
    parameter UART_STATUS_ADDR = 16'hA000,
    parameter UART_ACCESS_ADDR = 16'hA001,
    parameter LED_ADDR = 16'hA002,

    // UART
    `ifdef VERILATOR
    parameter UART_BAUD_DIV_RATE = 3'd05,
    parameter UART_BAUD_DIV_WIDTH = 3,
    `else
    parameter UART_BAUD_DIV_RATE = 12'd2604,
    parameter UART_BAUD_DIV_WIDTH = 12,
    `endif

    localparam UART_FIFO_DW = 8,
    localparam UART_FIFO_AW = 5,
    localparam UART_SHIFTER_WIDTH = 10,
    localparam UART_BITS_SIZE = 4
)(
    input   wire                            i_clk,

    /*********************
    * Memory adapter bus
    **********************/
    // Wishbone bus for memory adapter
    input   wire                            i_wb_mem_adapter_cyc,
    input   wire                            i_wb_mem_adapter_stb,
    input   wire                            i_wb_mem_adapter_we,
    input   wire    [CPU_ADDR_WIDTH-1:0]    i_wb_mem_adapter_addr,
    input   wire    [CPU_DATA_WIDTH-1:0]    i_wb_mem_adapter_data,
    output  wire                            o_wb_mem_adapter_ack,
    output  wire                            o_wb_mem_adapter_stall,
    output  wire    [CPU_DATA_WIDTH-1:0]    o_wb_mem_adapter_data,

    // ROM address bus
    output  wire    [ROM_ADDR_WIDTH-1:0]    o_mem_adapter_rom_addr,
    output  wire                            o_mem_adapter_rom_stb,
    input   wire    [CPU_DATA_WIDTH-1:0]    i_mem_adapter_rom_data,

    // RAM address bus
    output  wire    [RAM_ADDR_WIDTH-1:0]    o_mem_adapter_ram_addr,
    output  wire                            o_mem_adapter_ram_stb,
    output  wire                            o_mem_adapter_ram_wr,
    input   wire    [CPU_DATA_WIDTH-1:0]    i_mem_adapter_ram_data,
    output  wire    [CPU_DATA_WIDTH-1:0]    o_mem_adapter_ram_data,

    // FIFO memory access for UARTs
    output reg  	[UART_FIFO_AW-1:0]	    o_fifo_uart_rx_mem_addr_w,
	output reg  	[UART_FIFO_AW-1:0]	    o_fifo_uart_rx_mem_addr_r,
	output reg  				            o_fifo_uart_rx_mem_we,
	input  wire  	[UART_FIFO_DW-1:0]	    i_fifo_uart_rx_mem_data_read,
	output reg  	[UART_FIFO_DW-1:0]	    o_fifo_uart_rx_mem_data_write,

    output reg  	[UART_FIFO_AW-1:0]	    o_fifo_uart_tx_mem_addr_w,
	output reg  	[UART_FIFO_AW-1:0]	    o_fifo_uart_tx_mem_addr_r,
	output reg  				            o_fifo_uart_tx_mem_we,
	input  wire  	[UART_FIFO_DW-1:0]	    i_fifo_uart_tx_mem_data_read,
	output reg  	[UART_FIFO_DW-1:0]	    o_fifo_uart_tx_mem_data_write,

    /*********************
    * Outside connections
    **********************/
    output  reg                             o_completed_op_led,
    input   wire                            i_uart_rx,
    output  wire                            o_uart_tx
);

    // Reset controller
    wire reset_n;
    reset_controller RESET_CNT(
        .i_clk      (i_clk),
        .o_reset_n  (reset_n)
    );

    // UART RX
    wire                    i_wb_uart_rx_stb;
    wire                    i_wb_uart_rx_cyc;
    wire     [7:0]          o_wb_uart_rx_data;
    wire                    o_wb_uart_rx_ack;
    wire                    o_wb_uart_rx_stall;
    wire                    o_wb_uart_rx_empty;

    wb_uart_rx #(
        .BAUD_DIV_RATE          (UART_BAUD_DIV_RATE),
        .BAUD_DIV_WIDTH         (UART_BAUD_DIV_WIDTH)
    ) UART_RX(
        .i_clk                  (i_clk),
        .i_reset_n              (reset_n),

        .i_wb_stb               (i_wb_uart_rx_stb),
        .i_wb_cyc               (i_wb_uart_rx_cyc),
        .o_wb_data              (o_wb_uart_rx_data),
        .o_wb_ack               (o_wb_uart_rx_ack),
        .o_wb_stall             (o_wb_uart_rx_stall),

        .o_fifo_mem_addr_w      (o_fifo_uart_rx_mem_addr_w),
        .o_fifo_mem_addr_r      (o_fifo_uart_rx_mem_addr_r),
        .o_fifo_mem_we          (o_fifo_uart_rx_mem_we),
        .i_fifo_mem_data_read   (i_fifo_uart_rx_mem_data_read),
        .o_fifo_mem_data_write  (o_fifo_uart_rx_mem_data_write),

        .uart_rx                (i_uart_rx),
        .uart_empty             (o_wb_uart_rx_empty)
    );

    // UART TX
    wire                        i_wb_uart_tx_stb;
    wire                        i_wb_uart_tx_cyc;
    wire     [7:0]              i_wb_uart_tx_data;
    wire                        o_wb_uart_tx_ack;
    wire                        o_wb_uart_tx_stall;

    wb_uart_tx #(
        .BAUD_DIV_RATE          (UART_BAUD_DIV_RATE),
        .BAUD_DIV_WIDTH         (UART_BAUD_DIV_WIDTH)
    ) UART_TX(
        .i_clk                  (i_clk),
        .i_reset_n              (reset_n),

        .i_wb_stb               (i_wb_uart_tx_stb),
        .i_wb_cyc               (i_wb_uart_tx_cyc),
        .i_wb_data              (i_wb_uart_tx_data),
        .o_wb_ack               (o_wb_uart_tx_ack),
        .o_wb_stall             (o_wb_uart_tx_stall),

        .o_fifo_mem_addr_w      (o_fifo_uart_tx_mem_addr_w),
        .o_fifo_mem_addr_r      (o_fifo_uart_tx_mem_addr_r),
        .o_fifo_mem_we          (o_fifo_uart_tx_mem_we),
        .i_fifo_mem_data_read   (i_fifo_uart_tx_mem_data_read),
        .o_fifo_mem_data_write  (o_fifo_uart_tx_mem_data_write),

        .uart_tx                (o_uart_tx)
    );

    // Memory adapter
    wb_mem_adapter MEM_ADAPTER(
        .i_clk                  (i_clk),
        .i_reset_n              (reset_n),
        .i_wb_cyc               (i_wb_mem_adapter_cyc),
        .i_wb_stb               (i_wb_mem_adapter_stb),
        .i_wb_we                (i_wb_mem_adapter_we),
        .i_wb_addr              (i_wb_mem_adapter_addr),
        .i_wb_data              (i_wb_mem_adapter_data),
        .o_wb_ack               (o_wb_mem_adapter_ack),
        .o_wb_stall             (o_wb_mem_adapter_stall),
        .o_wb_data              (o_wb_mem_adapter_data),

        .o_rom_addr             (o_mem_adapter_rom_addr),
        .o_rom_stb              (o_mem_adapter_rom_stb),
        .i_rom_data             (i_mem_adapter_rom_data),

        .o_ram_addr             (o_mem_adapter_ram_addr),
        .o_ram_stb              (o_mem_adapter_ram_stb),
        .o_ram_wr               (o_mem_adapter_ram_wr),
        .i_ram_data             (i_mem_adapter_ram_data),
        .o_ram_data             (o_mem_adapter_ram_data),

        .o_wb_rx_stb            (i_wb_uart_rx_stb),
        .o_wb_rx_cyc            (i_wb_uart_rx_cyc),
        .i_wb_rx_data           (o_wb_uart_rx_data),
        .i_wb_rx_stall          (o_wb_uart_rx_stall),
        .i_wb_rx_ack            (o_wb_uart_rx_ack),
        .rx_empty               (o_wb_uart_rx_empty),

        .o_wb_tx_stb            (i_wb_uart_tx_stb),
        .o_wb_tx_cyc            (i_wb_uart_tx_cyc),
        .o_wb_tx_data           (i_wb_uart_tx_data),
        .i_wb_tx_ack            (o_wb_uart_tx_ack),
        .i_wb_tx_stall          (o_wb_uart_tx_stall),

        .o_completed_op_led     (o_completed_op_led)
    );

endmodule