`default_nettype none
/*
 * clk_divider
 *
 * Simple clock divider. Divides input clock signal based on a counter with the specified rate value (as a parameter).
 *
 * i_start_stb -> starts the clock division (if it isn't active yet)
 * i_reset_stb -> stops the clock division (if it's currently active) and resets its internal state
 */
module clk_divider
#(
    `ifdef VERILATOR
    parameter CLK_DIVIDER_RATE = 4'd10,
    parameter CLK_DIVIDER_WIDTH = 4
    `else
    parameter CLK_DIVIDER_RATE = 12'd2604,
    parameter CLK_DIVIDER_WIDTH = 12
    `endif
)(
    input       wire            i_clk,
    input       wire            i_reset_n,
    input       wire            i_start_stb,
    input       wire            i_reset_stb,
    output      reg             o_div_clk,
    output      reg             o_div_clk_rose
);

    /******************
     * DATA PATH
    ******************/
    localparam FULL_COUNT = CLK_DIVIDER_RATE - 1'b1;
    localparam ZERO_COUNT = {CLK_DIVIDER_WIDTH{1'b0}};

    reg     [CLK_DIVIDER_WIDTH-1:0]     cnt_clk_div;

    reg reset_count;

    // Counter for clock division
    always @(posedge i_clk) begin
        if (!i_reset_n||reset_count) begin
            cnt_clk_div <= FULL_COUNT;
        end else if (state == STATE_COUNTING) begin
            cnt_clk_div <= (cnt_clk_div == ZERO_COUNT) ? FULL_COUNT : cnt_clk_div - 1'b1;
        end else cnt_clk_div <= FULL_COUNT;
    end

    // Switching the clock at the right time
    always @(posedge i_clk) begin
        if (!i_reset_n||reset_count) begin
            o_div_clk <= 1'b1;
        end else if (cnt_clk_div == ZERO_COUNT) begin
            o_div_clk <= ~o_div_clk;
        end
    end

    // Letting components know about change in clock state to positive edge
    always @(posedge i_clk) begin
        o_div_clk_rose <= cnt_clk_div == ZERO_COUNT && o_div_clk == 1'b0;
    end

    /******************
     * FSM
    ******************/
    reg state;
    /* verilator lint_off UNOPTFLAT */
    reg state_next;
    /* verilator lint_on UNOPTFLAT */

    localparam STATE_IDLE = 1'd0;
    localparam STATE_COUNTING = 1'd1;

    reg transition_idle_to_count;
    reg transition_back_to_idle;

    always @(*) begin
        if (!i_reset_n) begin
            transition_idle_to_count        = 1'b0;
            transition_back_to_idle         = 1'b0;
        end else begin
            transition_idle_to_count        = state == STATE_IDLE && i_reset_n && i_start_stb && !i_reset_stb;
            transition_back_to_idle         = state == STATE_COUNTING && i_reset_stb;
        end
    end

    always @(*) begin
        if (!i_reset_n) begin
            state_next = STATE_IDLE;
        end else begin
            state_next = (transition_idle_to_count) ? STATE_COUNTING : state_next;
            state_next = (transition_back_to_idle)  ? STATE_IDLE : state_next;
        end
    end

    always @(posedge i_clk) begin
        if (!i_reset_n) begin
            state <= STATE_IDLE;
        end else begin
            state <= state_next;
        end        
    end

    always @(*) begin
        reset_count = transition_back_to_idle;
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

    // Initial conditions
    initial assume(!i_reset_n);
    initial assume(!i_start_stb);

    // Strobe signals are 1-cycle long
    always @(posedge i_clk) begin
        if (f_past_valid && $past(i_start_stb))
            assume(!i_start_stb);

        if (f_past_valid && $past(i_reset_stb))
            assume(!i_reset_stb);
    end

    reg f_not_ext_reset;
    reg f_not_any_reset;
    always @(*) begin
        f_not_ext_reset = i_reset_n;
        f_not_any_reset = f_not_ext_reset && !i_reset_stb;
    end

    // Initial/reset state should have us not counting - and not changing clock cycle
    always @(posedge i_clk) begin
        if (f_past_valid && $past(!i_reset_n||i_reset_stb) && $past(!i_start_stb) && !i_start_stb) begin
            assert(state == STATE_IDLE && cnt_clk_div != ZERO_COUNT);
        end 
    end

    // Idle clock is always 1'b1
    always @(posedge i_clk) begin
        if (f_past_valid && $past(state == STATE_IDLE) && state == STATE_IDLE) begin
            assert(o_div_clk == 1'b1);
        end 
    end

    // If the clock divider count reaches 0, we need to swap the clock state
    always @(posedge i_clk) begin
        if (f_past_valid && f_not_any_reset && $past(f_not_any_reset) && $past(cnt_clk_div == ZERO_COUNT)) begin
            assert(o_div_clk != $past(o_div_clk));
        end
    end

    // Start strobe makes the counting process begin
    always @(posedge i_clk) begin
        if (f_past_valid && f_not_any_reset && $past(f_not_any_reset) && $past(f_not_any_reset, 2) && $past(i_start_stb && state == STATE_IDLE, 2)) begin
            assert(cnt_clk_div == FULL_COUNT - 1'b1);
        end
    end

    
`endif

endmodule