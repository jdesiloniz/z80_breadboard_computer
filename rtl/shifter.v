`default_nettype none
/*
* shifter     
* 
* Simple bit-by-bit shifter, enabling combinational shift and rotate ops.
*
* `i_op`:
*   3'd0: shift left with 0 padding (abcdefgh -> bcdefgh0)
*   3'd1: shift right with 0 padding (abcdefgh -> 0abcdefg)
*   3'd2: shift left with 1 padding (abcdefgh -> bcdefgh1)
*   3'd3: shift right with 1 padding (abcdefgh -> 1abcdefg)
*   3'd4: rotate left (abcdefgh -> bcdefgha)
*   3'd5: rotate right (abcdefgh -> habcdefg)
*/
module shifter
#(
    parameter DATA_WIDTH = 10
)(
    input   wire                        i_clk,
    input	wire	[DATA_WIDTH-1:0]	i_data,
    input   wire    [2:0]               i_op,
	output	reg 	[DATA_WIDTH-1:0]	o_data
);

    localparam DATA_ZERO = {DATA_WIDTH{1'b0}};

    localparam OP_SHIFT_LEFT_ZERO   = 3'd0;
    localparam OP_SHIFT_RIGHT_ZERO  = 3'd1;
    localparam OP_SHIFT_LEFT_ONE    = 3'd2;
    localparam OP_SHIFT_RIGHT_ONE   = 3'd3;
    localparam OP_ROTATE_LEFT       = 3'd4;
    localparam OP_ROTATE_RIGHT      = 3'd5;    

    always @(posedge i_clk) begin
        case (i_op)
            OP_SHIFT_LEFT_ZERO:     o_data <= {i_data[DATA_WIDTH-2:0], 1'b0};
            OP_SHIFT_RIGHT_ZERO:    o_data <= {1'b0, i_data[DATA_WIDTH-1:1]};
            OP_SHIFT_LEFT_ONE:      o_data <= {i_data[DATA_WIDTH-2:0], 1'b1};
            OP_SHIFT_RIGHT_ONE:     o_data <= {1'b1, i_data[DATA_WIDTH-1:1]};
            OP_ROTATE_LEFT:         o_data <= {i_data[DATA_WIDTH-2:0], i_data[DATA_WIDTH-1]};
            OP_ROTATE_RIGHT:        o_data <= {i_data[0], i_data[DATA_WIDTH-1:1]};
            default:                o_data <= i_data;
        endcase     
    end

`ifdef FORMAL
`ifdef SHIFTER
    reg f_past_valid;
	initial f_past_valid = 0;

	always @(posedge i_clk) begin
		f_past_valid <= 1'b1;
	end

    // No op condition
    always @(posedge i_clk)
        if (f_past_valid && $past(i_op > OP_ROTATE_RIGHT))
            assert(o_data == $past(i_data));

    // Shift left with zero padding
    always @(posedge i_clk) begin
        if (f_past_valid && $past(i_op == OP_SHIFT_LEFT_ZERO)) begin
            assert(o_data[0] == 1'b0);
            assert(o_data[DATA_WIDTH-1:1] == $past(i_data[DATA_WIDTH-2:0]));
        end
    end

    // Shift left with one padding
    always @(posedge i_clk) begin
        if (f_past_valid && $past(i_op == OP_SHIFT_LEFT_ONE)) begin
            assert(o_data[0] == 1'b1);
            assert(o_data[DATA_WIDTH-1:1] == $past(i_data[DATA_WIDTH-2:0]));
        end
    end

    // Shift right with zero padding
    always @(posedge i_clk) begin
        if (f_past_valid && $past(i_op == OP_SHIFT_RIGHT_ZERO)) begin
            assert(o_data[DATA_WIDTH-1] == 1'b0);
            assert(o_data[DATA_WIDTH-2:0] == $past(i_data[DATA_WIDTH-1:1]));
        end
    end

    // Shift right with one padding
    always @(posedge i_clk) begin
        if (f_past_valid && $past(i_op == OP_SHIFT_RIGHT_ONE)) begin
            assert(o_data[DATA_WIDTH-1] == 1'b1);
            assert(o_data[DATA_WIDTH-2:0] == $past(i_data[DATA_WIDTH-1:1]));
        end
    end

    // Rotate left
    always @(posedge i_clk) begin
        if (f_past_valid && $past(i_op == OP_ROTATE_LEFT)) begin
            assert(o_data[0] == $past(i_data[DATA_WIDTH-1]));
            assert(o_data[DATA_WIDTH-1:1] == $past(i_data[DATA_WIDTH-2:0]));
        end
    end

    // Rotate right
    always @(posedge i_clk) begin
        if (f_past_valid && $past(i_op == OP_ROTATE_RIGHT)) begin
            assert(o_data[DATA_WIDTH-1] == $past(i_data[0]));
            assert(o_data[DATA_WIDTH-2:0] == $past(i_data[DATA_WIDTH-1:1]));
        end
    end

`endif
`endif

endmodule