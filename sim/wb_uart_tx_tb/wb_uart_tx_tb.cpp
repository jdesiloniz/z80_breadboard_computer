#include <verilatedos.h>
#include <stdio.h>
#include <fcntl.h>
#include <unistd.h>
#include <string.h>
#include <time.h>
#include <sys/types.h>
#include <signal.h>
#include <iostream>
#include <fstream>
#include <time.h>
#include "verilated.h"
#include "Vwb_uart_tx.h"
#include "Vwb_fifo.h"
#include "Vclk_divider.h"
#include "testb.h"

#define MAX_FIFO_ITEMS 31

using namespace std;

unsigned fifo_buffer[MAX_FIFO_ITEMS];

void update_simulation(TESTB<Vwb_uart_tx> *tb, TESTB<Vwb_fifo> *fifo_tb, TESTB<Vclk_divider> *clk_div_tb) {
	// Connect FIFO with UART (PUSH side):
	tb->m_core->i_wb_push_fifo_ack = fifo_tb->m_core->o_wb_push_ack;
	tb->m_core->i_wb_push_fifo_stall = fifo_tb->m_core->o_wb_push_stall;
	fifo_tb->m_core->i_wb_push_stb = tb->m_core->o_wb_push_fifo_stb;
	fifo_tb->m_core->i_wb_push_data = tb->m_core->o_wb_push_fifo_data;
	fifo_tb->m_core->i_wb_push_cyc = tb->m_core->o_wb_push_fifo_cyc;

	// Connect FIFO with UART (PUSH side):
	tb->m_core->i_wb_pop_fifo_data = fifo_tb->m_core->o_wb_pop_data;
	tb->m_core->i_wb_pop_fifo_ack = fifo_tb->m_core->o_wb_pop_ack;
	tb->m_core->i_fifo_empty = fifo_tb->m_core->empty;
	fifo_tb->m_core->i_wb_pop_stb = tb->m_core->o_wb_pop_fifo_stb;
	fifo_tb->m_core->i_wb_pop_cyc = tb->m_core->o_wb_pop_fifo_cyc;

	// Connect clock dividier to UART
	tb->m_core->i_clk_div_clk = clk_div_tb->m_core->o_div_clk;
	clk_div_tb->m_core->i_start_stb = tb->m_core->o_clk_div_start_stb;
	clk_div_tb->m_core->i_reset_stb = tb->m_core->o_clk_div_reset_stb;

	// FIFO mem write op
	if (fifo_tb->m_core->mem_we) {
		fifo_buffer[fifo_tb->m_core->mem_addr_w] = fifo_tb->m_core->mem_data_write;
	}

	// FIFO mem read op
	fifo_tb->m_core->mem_data_read = fifo_buffer[fifo_tb->m_core->mem_addr_r];

	clk_div_tb->tick();
	fifo_tb->tick();
	tb->tick();
}

void wait_clocks(TESTB<Vwb_uart_tx> *tb, TESTB<Vwb_fifo> *fifo_tb, TESTB<Vclk_divider> *clk_div_tb, unsigned clocks) {
	for (unsigned i = 0; i < clocks; i++) {
		update_simulation(tb, fifo_tb, clk_div_tb);
	}
}

void print_fifo_state(TESTB<Vwb_fifo> *fifo_tb) {
	printf("[FIFO] empty: %d, full: %d\n", fifo_tb->m_core->empty, fifo_tb->m_core->full);
}
/*
void push_data(TESTB<Vwb_uart_tx> *tb, TESTB<Vwb_fifo> *fifo_tb, unsigned data) {
	fifo_tb->m_core->i_wb_push_data = data;
	fifo_tb->m_core->i_wb_push_stb = 1;
	fifo_tb->m_core->i_wb_push_cyc = 1;
	wait_clocks(tb, fifo_tb, 1);
	fifo_tb->m_core->i_wb_push_stb = 0;
	fifo_tb->m_core->i_wb_push_cyc = 0;
	wait_clocks(tb, fifo_tb, 1);

	printf("[TEST] Pushed data: %04X\n", data);
}

void push_data_n(TESTB<Vwb_uart_tx> *tb, TESTB<Vwb_fifo> *fifo_tb, unsigned times) {
	for (int i = 0; i < times; i++) {
		int value = (rand() % 100) + 1;
		push_data(tb, fifo_tb, value);
	}
}

std::vector<unsigned> push_data_array(TESTB<Vwb_uart_tx> *tb, TESTB<Vwb_fifo> *fifo_tb, unsigned times) {
	std::vector<unsigned> result;

	for (int i = 0; i < times; i++) {
		int value = (rand() % 100) + 1;
		push_data(tb, fifo_tb, value);
		result.push_back(value);
	}

	return result;
}*/

void push_data(TESTB<Vwb_uart_tx> *tb, TESTB<Vwb_fifo> *fifo_tb, TESTB<Vclk_divider> *clk_divider_tb, unsigned data) {
	tb->m_core->i_wb_data = data;
	tb->m_core->i_wb_stb = 1;
	tb->m_core->i_wb_cyc = 1;
	wait_clocks(tb, fifo_tb, clk_divider_tb, 1);
	tb->m_core->i_wb_stb = 0;
	tb->m_core->i_wb_cyc = 0;
	wait_clocks(tb, fifo_tb, clk_divider_tb, 1);

	printf("[TEST] Pushed data: %04X\n", data);
}

int	main(int argc, char **argv) {	
	Verilated::commandArgs(argc, argv);
	TESTB<Vwb_uart_tx> *tb = new TESTB<Vwb_uart_tx>;
	TESTB<Vwb_fifo> *fifo_tb = new TESTB<Vwb_fifo>;
	TESTB<Vclk_divider> *clk_div_tb = new TESTB<Vclk_divider>;

	tb->opentrace("wb_uart_tx.vcd");
	fifo_tb->opentrace("wb_fifo.vcd");
	clk_div_tb->opentrace("clk_div.vcd");

	// Initial reset 
	tb->m_core->i_reset_n = 0;
	fifo_tb->m_core->i_reset_n = 0;
	clk_div_tb->m_core->i_reset_n = 0;

	// Wait until starting
	wait_clocks(tb, fifo_tb, clk_div_tb, 10);

	tb->m_core->i_reset_n = 1;
	fifo_tb->m_core->i_reset_n = 1;
	clk_div_tb->m_core->i_reset_n = 1;

	// Wait a bit after reset
	printf("[TEST] Starting UART TX after reset...\n");
	wait_clocks(tb, fifo_tb, clk_div_tb, 10);

	// Let's push a byte into FIFO and see if it makes things going...
	push_data(tb, fifo_tb, clk_div_tb, 10);
	print_fifo_state(fifo_tb);
	wait_clocks(tb, fifo_tb, clk_div_tb, 1000);


	/*printf("[TEST] Initial FIFO state\n");
	print_fifo_state(tb);

	// Let's push some data and pop it later, we should go back to empty state...
	push_data_n(tb, 3);

	printf("[TEST] State after initial pushes\n");
	print_fifo_state(tb);

	printf("[TEST] State after subsequent pops\n");
	pop_data_n(tb, 3);
	print_fifo_state(tb);

	printf("[TEST] Filling FIFO\n");
	push_data_n(tb, MAX_FIFO_ITEMS);
	print_fifo_state(tb);

	printf("[TEST] Removing one element from FIFO to check full state\n");
	pop_data(tb);
	print_fifo_state(tb);

	pop_data_n(tb, MAX_FIFO_ITEMS); 	// Get it empty again
	print_fifo_state(tb);

	printf("[TEST] Filling FIFO again\n");
	std::vector<unsigned> data_in = push_data_array(tb, MAX_FIFO_ITEMS);
	print_fifo_state(tb);

	printf("[TEST] Checking data integrity\n");
	std::vector<unsigned> data_out = pop_data_array(tb, MAX_FIFO_ITEMS);
	print_fifo_state(tb);

	if (data_in != data_out) {
		printf("[TEST] Data inconsistency found.\n");
		printf("[TEST] Data in: ");
		for (std::vector<unsigned>::const_iterator i = data_in.begin(); i != data_in.end(); ++i) {
    		printf("%02X, ", *i);
		}
		printf("\n[TEST] Data out: ");
		for (std::vector<unsigned>::const_iterator i = data_out.begin(); i != data_out.end(); ++i) {
    		printf("%02X, ", *i);
		}
	}*/

	printf("\n\nSimulation complete\n");

}
