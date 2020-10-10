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
#include "Vwb_uart_rx.h"
#include "testb.h"
#include "uart_tx.h"

#define MAX_FIFO_ITEMS 31
#define UART_CHARS 10
#define UART_BAUDS 10

using namespace std;

unsigned fifo_buffer[MAX_FIFO_ITEMS];

void update_simulation(TESTB<Vwb_uart_rx> *tb, UartTx *uart_tx) {
	// FIFO mem write op
	if (tb->m_core->o_fifo_mem_we) {
		fifo_buffer[tb->m_core->o_fifo_mem_addr_w] = tb->m_core->o_fifo_mem_data_write;
	}

	// FIFO mem read op
	tb->m_core->i_fifo_mem_data_read = fifo_buffer[tb->m_core->o_fifo_mem_addr_r];

	// UART tx:
	tb->m_core->uart_rx = uart_tx->update_tx_uart();

	tb->tick();
}

void wait_clocks(TESTB<Vwb_uart_rx> *tb, UartTx *uart_tx, unsigned clocks) {
	for (unsigned i = 0; i < clocks; i++) {
		update_simulation(tb, uart_tx);
	}
}

void push_data(TESTB<Vwb_uart_rx> *tb, UartTx *uart_tx, unsigned data) {
	uart_tx->start_tx(data);
    wait_clocks(tb, uart_tx, 1);
}

void push_string_with_waits(TESTB<Vwb_uart_rx> *tb, UartTx *uart_tx, char text[]) {
	int length = strlen(text);
	for (int i = 0; i < length; i++) {
		while(uart_tx->tx_active) {
			wait_clocks(tb, uart_tx, 1);
		}
		push_data(tb, uart_tx, text[i]);
	}
}

void read_data_from_uart_fifo(TESTB<Vwb_uart_rx> *tb, UartTx *uart_tx) {
    if (tb->m_core->uart_empty) {
        printf("[UART] FIFO is empty... \n");
    } else {
        printf("[UART] Requested FIFO data: ");
    }
    while (!tb->m_core->uart_empty) {
        tb->m_core->i_wb_stb = 1;
        tb->m_core->i_wb_cyc = 1;
        wait_clocks(tb, uart_tx, 1);
        tb->m_core->i_wb_stb = 0;
        tb->m_core->i_wb_cyc = 0;

        while (tb->m_core->o_wb_ack == 0) {
            wait_clocks(tb, uart_tx, 1);
        }

        printf("%c", tb->m_core->o_wb_data);
    }
    printf("\n");
    return;
}

int	main(int argc, char **argv) {
	Verilated::commandArgs(argc, argv);

	TESTB<Vwb_uart_rx> *tb = new TESTB<Vwb_uart_rx>;
	UartTx *uart_tx = new UartTx();
	tb->opentrace("wb_uart_rx.vcd");

	// Initial reset 
	tb->m_core->i_reset_n = 0;

	// Wait until starting
	wait_clocks(tb, uart_tx, 10);

	tb->m_core->i_reset_n = 1;

	// Wait a bit after reset
	printf("[TEST] Starting UART RX after reset...\n");
	wait_clocks(tb, uart_tx, 10);

    // Let's send a short string through UART:
    printf("[TEST] Sending \"Hello world!\"...\n");
    char text[] = "Hello world!";
    push_string_with_waits(tb, uart_tx, text);
    wait_clocks(tb, uart_tx, 2000);

    // Check stored contents in UART RX FIFO:
    printf("[TEST] Requesting data from UART RX FIFO...\n");
    read_data_from_uart_fifo(tb, uart_tx);

    // A longer string should overrun the FIFO...:
    printf("\n[TEST] Sending longer string, final characters shouldn't be stored in the FIFO:");
	printf("\n[TEST] \"Lorem ipsum dolor sit amet, consectetur adipiscing elit sit.\"...\n");
    char text_too_much[] = "Lorem ipsum dolor sit amet, consectetur adipiscing elit sit.";
    push_string_with_waits(tb, uart_tx, text_too_much);
    wait_clocks(tb, uart_tx, 5000);

    // Check stored contents in UART RX FIFO:
    printf("[TEST] Requesting data from UART RX FIFO...\n");
    read_data_from_uart_fifo(tb, uart_tx);

    printf("\n\nSimulation complete\n");
}
