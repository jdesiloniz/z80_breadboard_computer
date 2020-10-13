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
#include "Vwb_test_bed.h"
#include "testb.h"

#define MAX_FIFO_ITEMS 31
#define ROM_SIZE 16384
#define RAM_SIZE 24576
#define UART_CHARS 10
#define UART_BAUDS 10

using namespace std;

unsigned fifo_buffer_rx[MAX_FIFO_ITEMS];
unsigned fifo_buffer_tx[MAX_FIFO_ITEMS];
unsigned rom[ROM_SIZE];
unsigned ram[RAM_SIZE];

/*
output  wire    [RAM_ADDR_WIDTH-1:0]    o_mem_adapter_ram_addr,
    output  wire                            o_mem_adapter_ram_stb,
    output  wire                            o_mem_adapter_ram_wr,
    input   wire    [CPU_DATA_WIDTH-1:0]    i_mem_adapter_ram_data,
    output  wire    [CPU_DATA_WIDTH-1:0]    o_mem_adapter_ram_data,
*/

unsigned general_addr_for_ram_addr(unsigned ram_addr) {
    return ROM_SIZE + ram_addr;
}

void update_ram(TESTB<Vwb_test_bed> *tb) {
    if (tb->m_core->o_mem_adapter_ram_stb == 1) {
        unsigned addr = tb->m_core->o_mem_adapter_ram_addr;

        if (tb->m_core->o_mem_adapter_ram_wr == 1) {
            unsigned data = tb->m_core->o_mem_adapter_ram_data;
            printf("[TEST] Written %02X into RAM address %02X\n", data, addr);
            ram[addr] = data;
        } else {
            unsigned data = ram[addr];
            printf("[TEST] Read from RAM address %02X value %02X\n", addr, data);
            tb->m_core->i_mem_adapter_ram_data = data;
        }
    }
}

void update_rom(TESTB<Vwb_test_bed> *tb) {
    if (tb->m_core->o_mem_adapter_rom_stb == 1 && tb->m_core->o_mem_adapter_rom_addr < ROM_SIZE) {
        tb->m_core->i_mem_adapter_rom_data = ram[tb->m_core->o_mem_adapter_rom_addr];
    }
}

void update_simulation(TESTB<Vwb_test_bed> *tb) {
    // Simple memory updates:
    update_rom(tb);
    update_ram(tb);

	tb->tick();
}

void wait_clocks(TESTB<Vwb_test_bed> *tb, unsigned clocks) {
	for (unsigned i = 0; i < clocks; i++) {
		update_simulation(tb);
	}
}

void write_operation(TESTB<Vwb_test_bed> *tb, unsigned address, unsigned byte) {
    while(tb->m_core->o_wb_mem_adapter_stall != 0) {
        wait_clocks(tb, 1);
    }

    tb->m_core->i_wb_mem_adapter_stb = 1;
    tb->m_core->i_wb_mem_adapter_cyc = 1;
    tb->m_core->i_wb_mem_adapter_we = 1;
    tb->m_core->i_wb_mem_adapter_addr = address;
    tb->m_core->i_wb_mem_adapter_data = byte;
    wait_clocks(tb, 1);
    tb->m_core->i_wb_mem_adapter_stb = 0;
    tb->m_core->i_wb_mem_adapter_we = 0;
    wait_clocks(tb, 1);
    
    while(tb->m_core->o_wb_mem_adapter_stall != 0) {
        wait_clocks(tb, 1);
    }
    tb->m_core->i_wb_mem_adapter_cyc = 0;
}

unsigned read_operation(TESTB<Vwb_test_bed> *tb, unsigned address) {
    while(tb->m_core->o_wb_mem_adapter_stall != 0) {
        wait_clocks(tb, 1);
    }

    tb->m_core->i_wb_mem_adapter_stb = 1;
    tb->m_core->i_wb_mem_adapter_cyc = 1;
    tb->m_core->i_wb_mem_adapter_we = 0;
    tb->m_core->i_wb_mem_adapter_addr = address;
    wait_clocks(tb, 1);
    tb->m_core->i_wb_mem_adapter_stb = 0;
    wait_clocks(tb, 1);
    
    // TODO: fix stall/ack in external memory ports:
    //while(tb->m_core->o_wb_mem_adapter_stall != 0) {
    //    wait_clocks(tb, 1);
    //}
    wait_clocks(tb, 5);

    tb->m_core->i_wb_mem_adapter_cyc = 0;

    unsigned read_value = tb->m_core->o_wb_mem_adapter_data;

    return read_value;
}

int	main(int argc, char **argv) {
	Verilated::commandArgs(argc, argv);

	TESTB<Vwb_test_bed> *tb = new TESTB<Vwb_test_bed>;
	tb->opentrace("wb_test_bed.vcd");

	// Wait a bit after reset
	printf("[TEST] Starting TEST BED...\n");
	wait_clocks(tb, 100);

    write_operation(tb, general_addr_for_ram_addr(0), 100);
    read_operation(tb, general_addr_for_ram_addr(0));

    // TODO: prepare some data for ROM and test ROM reads

    // TODO: check UART RX/TX and state register

    printf("\n\nSimulation complete\n");
}
