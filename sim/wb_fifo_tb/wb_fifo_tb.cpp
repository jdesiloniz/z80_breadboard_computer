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
#include "Vwb_fifo.h"
#include "testb.h"

#define MAX_FIFO_ITEMS 31

using namespace std;

unsigned fifo_buffer[MAX_FIFO_ITEMS];

void update_simulation(TESTB<Vwb_fifo> *tb) {
	// mem write op
	if (tb->m_core->mem_we) {
		fifo_buffer[tb->m_core->mem_addr_w] = tb->m_core->mem_data_write;
	}

	// mem read op
	tb->m_core->mem_data_read = fifo_buffer[tb->m_core->mem_addr_r];
	tb->tick();
}

void print_fifo_state(TESTB<Vwb_fifo> *tb) {
	printf("[FIFO] empty: %d, full: %d\n", tb->m_core->empty, tb->m_core->full);
}

void wait_clocks(TESTB<Vwb_fifo> *tb, unsigned clocks) {
	for (unsigned i = 0; i < clocks; i++) {
		update_simulation(tb);
	}
}

void push_data(TESTB<Vwb_fifo> *tb, unsigned data) {
	tb->m_core->i_wb_push_data = data;
	tb->m_core->i_wb_push_stb = 1;
	tb->m_core->i_wb_push_cyc = 1;
	wait_clocks(tb, 1);
	tb->m_core->i_wb_push_stb = 0;
	tb->m_core->i_wb_push_cyc = 0;
	wait_clocks(tb, 1);

	printf("[TEST] Pushed data: %04X\n", data);
}

void push_data_n(TESTB<Vwb_fifo> *tb, unsigned times) {
	for (int i = 0; i < times; i++) {
		int value = (rand() % 100) + 1;
		push_data(tb, value);
	}
}

unsigned pop_data(TESTB<Vwb_fifo> *tb) {
	tb->m_core->i_wb_pop_stb = 1;
	tb->m_core->i_wb_pop_cyc = 1;
	wait_clocks(tb, 1);
	tb->m_core->i_wb_pop_stb = 0;
	tb->m_core->i_wb_pop_cyc = 0;
	wait_clocks(tb, 1);
	unsigned result = tb->m_core->o_wb_pop_data;
	
	printf("[TEST] Popped data: %04X\n", result);

	return result;
}

void pop_data_n(TESTB<Vwb_fifo> *tb, unsigned times) {
	for (int i = 0; i < times; i++) {
		pop_data(tb);
	}
}

std::vector<unsigned> push_data_array(TESTB<Vwb_fifo> *tb, unsigned times) {
	std::vector<unsigned> result;

	for (int i = 0; i < times; i++) {
		int value = (rand() % 100) + 1;
		push_data(tb, value);
		result.push_back(value);
	}

	return result;
}

std::vector<unsigned> pop_data_array(TESTB<Vwb_fifo> *tb, unsigned times) {
	std::vector<unsigned> result;
	for (int i = 0; i < times; i++) {
		result.push_back(pop_data(tb));
	}

	return result;
}

int	main(int argc, char **argv) {	
	Verilated::commandArgs(argc, argv);
	TESTB<Vwb_fifo> *tb = new TESTB<Vwb_fifo>;

	tb->opentrace("wb_fifo.vcd");

	// Initial reset 
	tb->m_core->i_reset_n = 0;

	// Wait until starting
	wait_clocks(tb, 10);

	tb->m_core->i_reset_n = 1;

	printf("[TEST] Initial FIFO state\n");
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
	}

	printf("\n\nSimulation complete\n");

}
