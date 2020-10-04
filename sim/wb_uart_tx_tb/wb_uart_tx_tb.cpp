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
#include "testb.h"

#define MAX_FIFO_ITEMS 31

using namespace std;

unsigned fifo_buffer[MAX_FIFO_ITEMS];

void update_simulation(TESTB<Vwb_uart_tx> *tb) {
	// FIFO mem write op
	if (tb->m_core->o_fifo_mem_we) {
		fifo_buffer[tb->m_core->o_fifo_mem_addr_w] = tb->m_core->o_fifo_mem_data_write;
	}

	// FIFO mem read op
	tb->m_core->i_fifo_mem_data_read = fifo_buffer[tb->m_core->o_fifo_mem_addr_r];

	tb->tick();
}

void wait_clocks(TESTB<Vwb_uart_tx> *tb, unsigned clocks) {
	for (unsigned i = 0; i < clocks; i++) {
		update_simulation(tb);
	}
}

void push_data(TESTB<Vwb_uart_tx> *tb, unsigned data) {
	tb->m_core->i_wb_data = data;
	tb->m_core->i_wb_stb = 1;
	tb->m_core->i_wb_cyc = 1;
	wait_clocks(tb, 1);
	tb->m_core->i_wb_stb = 0;
	tb->m_core->i_wb_cyc = 0;
	wait_clocks(tb, 1);

	printf("[TEST] Pushed data: %02X\n", data);
}

int	main(int argc, char **argv) {	
	Verilated::commandArgs(argc, argv);

	TESTB<Vwb_uart_tx> *tb = new TESTB<Vwb_uart_tx>;
	tb->opentrace("wb_uart_tx.vcd");

	// Initial reset 
	tb->m_core->i_reset_n = 0;

	// Wait until starting
	wait_clocks(tb, 10);

	tb->m_core->i_reset_n = 1;

	// Wait a bit after reset
	printf("[TEST] Starting UART TX after reset...\n");
	wait_clocks(tb, 10);

	// Let's push a byte into FIFO and see if it makes things going...
	push_data(tb, 10);
	wait_clocks(tb, 1000);

	// TODO: implement UART RX and print characters...

	printf("\n\nSimulation complete\n");

}
