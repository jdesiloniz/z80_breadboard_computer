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
#include "uart_rx.h"

#define MAX_FIFO_ITEMS 31
#define UART_CHARS 10
#define UART_BAUDS 10

using namespace std;

unsigned fifo_buffer[MAX_FIFO_ITEMS];

void update_simulation(TESTB<Vwb_uart_tx> *tb, UartRx *uart_rx) {
	// FIFO mem write op
	if (tb->m_core->o_fifo_mem_we) {
		fifo_buffer[tb->m_core->o_fifo_mem_addr_w] = tb->m_core->o_fifo_mem_data_write;
	}

	// FIFO mem read op
	tb->m_core->i_fifo_mem_data_read = fifo_buffer[tb->m_core->o_fifo_mem_addr_r];

	// UART rx:
	uart_rx->update_rx_uart(tb->m_core->uart_tx);

	tb->tick();
}

void wait_clocks(TESTB<Vwb_uart_tx> *tb, UartRx *uart_rx, unsigned clocks) {
	for (unsigned i = 0; i < clocks; i++) {
		update_simulation(tb, uart_rx);
	}
}

void push_data(TESTB<Vwb_uart_tx> *tb, UartRx *uart_rx, unsigned data) {
	tb->m_core->i_wb_data = data;
	tb->m_core->i_wb_stb = 1;
	tb->m_core->i_wb_cyc = 1;
	wait_clocks(tb, uart_rx, 1);
	tb->m_core->i_wb_stb = 0;
	tb->m_core->i_wb_cyc = 0;
	wait_clocks(tb, uart_rx, 1);
}

void push_string(TESTB<Vwb_uart_tx> *tb, UartRx *uart_rx, char text[]) {
	int length = strlen(text);
	for (int i = 0; i < length; i++) {
		push_data(tb, uart_rx, text[i]);
	}
}

void push_string_with_waits(TESTB<Vwb_uart_tx> *tb, UartRx *uart_rx, char text[]) {
	int length = strlen(text);
	for (int i = 0; i < length; i++) {
		while(tb->m_core->o_wb_stall != 0) {
			wait_clocks(tb, uart_rx, 1);
		}
		push_data(tb, uart_rx, text[i]);
	}
} 

int	main(int argc, char **argv) {
	Verilated::commandArgs(argc, argv);

	TESTB<Vwb_uart_tx> *tb = new TESTB<Vwb_uart_tx>;
	UartRx *uart_rx = new UartRx();
	tb->opentrace("wb_uart_tx.vcd");

	// Initial reset 
	tb->m_core->i_reset_n = 0;

	// Wait until starting
	wait_clocks(tb, uart_rx, 10);

	tb->m_core->i_reset_n = 1;

	// Wait a bit after reset
	printf("[TEST] Starting UART TX after reset...\n");
	wait_clocks(tb, uart_rx, 10);

	// Let's push some text into FIFO and see if it makes things going...
	printf("[TEST] Pushing \"Hello world!\"...\n");
	printf("[UART] ...");
	char text[] = "Hello world!";
	push_string(tb, uart_rx, text);
	wait_clocks(tb, uart_rx, 2000);

	// Now let's overrun the FIFO with more characters than it can handle (60 bytes)...
	printf("\n[TEST] Pushing longer string, without waiting for full state:");
	printf("\n[TEST] \"Lorem ipsum dolor sit amet, consectetur adipiscing elit sit.\"...\n");
	printf("[UART] ...");
	char text_too_much[] = "Lorem ipsum dolor sit amet, consectetur adipiscing elit sit.";
	push_string(tb, uart_rx, text_too_much);
	wait_clocks(tb, uart_rx, 4000);

	// Finally let's use the stall mechanism from the FIFO and see if we get the whole string at the end:
	printf("\n[TEST] Pushing way long string:");
	printf("\n[TEST] \"Lorem ipsum dolor sit amet, consectetur adipiscing elit. Curabitur dapibus, orci eu malesuada tempor, lacus leo condimentum orci, non semper augue tellus a eros. Pellentesque viverra eu lorem ac quis.\"\n");
	printf("[UART] ...");
	char text_even_longer[] = "Lorem ipsum dolor sit amet, consectetur adipiscing elit. Curabitur dapibus, orci eu malesuada tempor, lacus leo condimentum orci, non semper augue tellus a eros. Pellentesque viverra eu lorem ac quis.";
	push_string_with_waits(tb, uart_rx, text_even_longer);
	wait_clocks(tb, uart_rx, 4000);

	printf("\n\nSimulation complete\n");

}
