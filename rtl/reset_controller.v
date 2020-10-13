module reset_controller #(
    `ifdef VERILATOR
    parameter RESET_RATE_COUNT = 4'd10,
    parameter RESET_RATE_COUNT_WIDTH = 4
    `else
    parameter RESET_RATE_COUNT = 26'd50_000_000,
    parameter RESET_RATE_COUNT_WIDTH = 26
    `endif
)(
    input   wire       i_clk,
    output  reg        o_reset_n
);
    localparam RESET_COUNT_ZERO = {RESET_RATE_COUNT_WIDTH{1'b0}};
    localparam RESET_COUNT_FULL = RESET_RATE_COUNT - 1'b1;

    reg     [RESET_RATE_COUNT_WIDTH-1:0]    reset_cnt;

    initial begin
        o_reset_n = 1'b0;
        reset_cnt = RESET_COUNT_ZERO;
    end

    // Reset signal
    always @(*) begin
        o_reset_n = reset_cnt == RESET_COUNT_FULL;
    end

    // Count up
    always @(posedge i_clk) begin
        reset_cnt <= (reset_cnt != RESET_COUNT_FULL) ? reset_cnt + 1'b1 : RESET_COUNT_FULL;
    end

`ifdef FORMAL
`ifdef RESET_CNT
    reg f_past_valid;
	initial f_past_valid = 0;

	always @(posedge i_clk) begin
		f_past_valid <= 1'b1;
	end

    initial assume(reset_cnt == RESET_COUNT_ZERO);

    // Assertions

    // The counter shouldn't go beyond the specified value
    always @(*)
        assert(reset_cnt <= RESET_COUNT_FULL);

    // When it's increasing it should be the expected rate
    always @(posedge i_clk)
        if (f_past_valid && $past(reset_cnt < RESET_COUNT_FULL))
            assert($past(reset_cnt + 1'b1) == reset_cnt);

    // Counter should never go down
    always @(posedge i_clk)
        if (f_past_valid)
            assert($past(reset_cnt) <= reset_cnt);

    // Reset signal should match the counter state
    always @(*)
        if (reset_cnt < RESET_COUNT_FULL)
            assert(!o_reset_n);
        

`endif
`endif

endmodule