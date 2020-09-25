`default_nettype none
/*
 * wb_fifo
 *
 * Simple FIFO queue on a Wishbone bus.
 *
 * `AW` = Address width for the memory buffer. Its size will be as large as it can be contained in such an address width (i.e.: `AW` = 5, memory buffer is 32 words).
 * `DW` = Word data size. Careful: should be a valid value for a memory that supports this. 
 *
 * Warnings:
 * 	- Because of limitations of the implementation, `i_reset_n` signal should be held at least for 2 clock cycles to guarantee a valid initial state.
 *	- Memory should be dual-port supporting simultaneous reads and writes (but not at the same addresses).
 * 
 * Special signals:
 *
 * `full`: signals that the FIFO buffer is full. No writes/pushes will be accepted at this point until data is popped from the queue.
 * `empty`: signals that the FIFO buffer is empty. Reads aren't considered valid in this condition.
 *
 * Regarding back pressure:
 *
 * - Back pressure is enforced by the `full` signal, even though to comply with Wishbone bus standard that value is mapped to `o_wb_stall`.
 * - All valid operations (any reads/pop or all writes/pushes except if FIFO is full) are signaled with an `o_wb_ack` positive signal 1 clock cycle after the request.
 * - Requests are 1 clock long so they can't be cancelled, thus this module effectively ignores `i_wb_cyc`.
 */
module wb_fifo
#(
    parameter DW = 8,
    parameter AW = 5
)(
    input 	wire	 			i_clk,
    input   wire                i_reset_n,

    // Wishbone push bus
	input	wire	[DW-1:0]	i_wb_push_data,
	input	wire 				i_wb_push_stb,
	/* verilator lint_off UNUSED */
    input	wire 				i_wb_push_cyc,
	/* verilator lint_on UNUSED */
    output  reg                 o_wb_push_stall,
    output  reg                 o_wb_push_ack,

	// Wishbone pop bus
	input	wire 				i_wb_pop_stb,
	/* verilator lint_off UNUSED */
    input	wire 				i_wb_pop_cyc,
	/* verilator lint_on UNUSED */
	output	reg 	[DW-1:0]	o_wb_pop_data,
    output  reg                 o_wb_pop_stall,
    output  reg                 o_wb_pop_ack,
    
    // Empty/full condition
	output 	reg 				full,
	output 	reg 				empty,

	// Memory access
	output reg  	[AW-1:0]	mem_addr_w,
	output reg  	[AW-1:0]	mem_addr_r,
	output reg  				mem_we,			// Write enable doesn't mean that reads aren't enabled
	input  wire  	[DW-1:0]	mem_data_read,
	output reg  	[DW-1:0]	mem_data_write
);
    /******************
     * DATA PATH
    ******************/

    localparam MAX_ADDR = {AW{1'b1}};
    localparam ADDR_ZERO = {AW{1'b0}};

	// Address pointers
	reg 	[AW-1:0]	ptr_writes;
	reg 	[AW-1:0]	ptr_reads;
	reg 	[AW-1:0]	ptr_writes_after;
    reg 	[AW-1:0]	ptr_reads_after;

    // Commands
    reg cmd_push;
    reg cmd_pop;

    // Push/pull condition
    always @(posedge i_clk) begin
        if (!i_reset_n) begin
            ptr_writes <= 0;
		    ptr_reads <= 0;    
		end else begin
			if (cmd_push) begin
            	ptr_writes <= ptr_writes_after;
			end

			if (cmd_pop) begin
            	ptr_reads <= ptr_reads_after;
        	end
        end
    end

    // Pointers' next values
    always @(*) begin
        ptr_reads_after 	= (ptr_reads >= MAX_ADDR - 1'b1) ? ADDR_ZERO : ptr_reads + 1'b1;
        ptr_writes_after    = (ptr_writes >= MAX_ADDR - 1'b1) ? ADDR_ZERO : ptr_writes + 1'b1;
    end

    // Full / empty signals
    always @(*) begin
        full = (ptr_writes_after == ptr_reads);
        empty = (ptr_writes == ptr_reads);
    end
	
	// Memory bus control
    always @(*) begin
        mem_we = cmd_push;
        mem_data_write = i_wb_push_data;
        mem_addr_r = ptr_reads;
        mem_addr_w = ptr_writes;
        o_wb_pop_data = mem_data_read;
    end

	// Push
	always @(*)
        if (!i_reset_n)
            cmd_push = 1'b0;
        else cmd_push = i_wb_push_stb && !full;

	// Pop
	always @(*)
        if (!i_reset_n)
            cmd_pop = 1'b0;
        else cmd_pop = i_wb_pop_stb && !empty;

    // Stall/acks
    always @(*) begin
        o_wb_push_stall = full;
		o_wb_pop_stall = 1'b0;
    end

    always @(posedge i_clk) begin
        // Acks will come 1 clock after an operation request (if not full), as the command is sent synchronously
        o_wb_push_ack <= cmd_push && !o_wb_push_stall;
		o_wb_pop_ack <= cmd_pop;
    end

/*********************
* Formal verification
**********************/
`ifdef FORMAL
`ifdef FIFO
	reg f_past_valid;
	initial f_past_valid = 0;

	always @(posedge i_clk) begin
		f_past_valid <= 1'b1;
	end

    // Assumptions
    initial assume(!i_reset_n);

    // STB and CYC are tied
    always @(*)
		if (i_wb_push_stb)
			assume(i_wb_push_cyc);

	always @(*)
		if (i_wb_pop_stb)
			assume(i_wb_pop_cyc);

    // Strobe signals are 1-cycle long
    always @(posedge i_clk) begin
        if (f_past_valid && $past(i_wb_push_stb))
            assume(!i_wb_push_stb);
    end

	always @(posedge i_clk) begin
        if (f_past_valid && $past(i_wb_pop_stb))
            assume(!i_wb_pop_stb);
    end

    // Check the state during a reset
    always @(posedge i_clk) begin
        if (f_past_valid && $past(!i_reset_n) && !i_reset_n) begin
            assert(!o_wb_push_ack && !o_wb_pop_ack && !o_wb_push_stall && !o_wb_pop_stall && empty && !full && !mem_we);
        end
    end

	// FIFO can't write nor read beyond the memory limits
	always @(posedge i_clk)
        if (i_reset_n)
		    assert(ptr_writes < MAX_ADDR && ptr_reads < MAX_ADDR);

	// FIFO's full signal should always be active if we're really full
	always @(*)
		if (ptr_writes_after == ptr_reads)
			assert(full);

	// Same for empty signal
	always @(*)
		if (ptr_writes == ptr_reads)
			assert(empty);

	// Writing to a full FIFO doesn't have any effect
	always @(posedge i_clk)
		if (f_past_valid && $past(i_reset_n) && i_reset_n && $past(i_wb_push_stb && !i_wb_pop_stb) && $past(full))
			assert(full && $stable(ptr_writes));

	// Reading from an empty FIFO doesn't have any effect
	always @(posedge i_clk)
		if (f_past_valid && $past(i_reset_n) && i_reset_n && $past(i_wb_pop_stb && !i_wb_push_stb) && $past(empty))
			assert(empty && $past(ptr_reads) == ptr_reads);

	// While writing we don't touch the reading pointer
	always @(posedge i_clk)
		if (f_past_valid && $past(i_reset_n) && i_reset_n && $past(i_wb_push_stb && !i_wb_pop_stb))
			assert($past(ptr_reads) == ptr_reads);

	// And vice-versa...
	always @(posedge i_clk)
		if (f_past_valid && $past(i_reset_n) && i_reset_n && $past(i_wb_pop_stb && !i_wb_push_stb))
			assert($past(ptr_writes) == ptr_writes);

	// Obviously we can write to a non-full FIFO
	always @(posedge i_clk)
		if (f_past_valid && $past(i_reset_n) && i_reset_n && $past(i_wb_push_stb) && $past(!full))
			assert(ptr_writes == $past(ptr_writes_after));

	// And we can read from a non-empty FIFO
	always @(posedge i_clk)
		if (f_past_valid && $past(i_reset_n) && i_reset_n && $past(i_wb_pop_stb) && $past(!empty))
			assert(ptr_reads == $past(ptr_reads_after));

	// Check we're reading the right data from memory
	always @(posedge i_clk)
		if ($past(i_wb_pop_stb && !empty && i_reset_n) && i_reset_n)
			assert($past(mem_addr_r == ptr_reads) && o_wb_pop_data == mem_data_read);

	// And we're writing the right data to memory
	always @(posedge i_clk)
		if (i_wb_push_stb && !full && $past(i_reset_n) && i_reset_n)
			assert(mem_data_write == i_wb_push_data && mem_we && mem_addr_w == ptr_writes);

	// Also that we can't write to memory if FIFO is full
	always @(posedge i_clk)
		if (f_past_valid && $past(i_reset_n) && i_reset_n && $past(i_wb_push_stb) && $past(full))
			assert($stable(ptr_writes));

	// We shouldn't get into a full situation after a pull
	always @(posedge i_clk)
		if (f_past_valid && $past(i_reset_n) && i_reset_n && $past(i_wb_pop_stb))
			assert(!full);

	// And obviously it should be impossible to be empty after a push
	always @(posedge i_clk)
		if (f_past_valid && $past(i_reset_n) && i_reset_n && $past(i_wb_push_stb))
			assert(!empty);

    // There's no back pressure unless we're full so we should be acking as soon as we get a valid memory result (i.e.: 1 cycle after request)
    always @(posedge i_clk)
		if (f_past_valid && $past(i_reset_n && i_wb_push_stb && !o_wb_push_stall) && i_reset_n)
			assert(o_wb_push_ack);
	
	// We should always ack 1 clock cycle after a pop
	always @(posedge i_clk)
		if (f_past_valid && $past(i_reset_n && i_wb_pop_stb && !empty) && i_reset_n)
			assert(o_wb_pop_ack);

    // We shouldn't stall unless we're full
    always @(*)
		assert(o_wb_push_stall == full);
`endif
`endif

endmodule