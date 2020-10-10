#include <stdio.h>
#include "uart_tx.h"

UartTx::UartTx()
{
    init_tx_uart();
}

void UartTx::init_tx_uart() {
    tx_byte = 0;
	tx_clock = ((UART_CHARS + 1) * (UART_BAUDS - 1));
	tx_active = false;
}

void UartTx::shift_tx() {
    tx_byte = tx_byte >> 1;
}

void UartTx::start_tx(unsigned byte) {
    if (!tx_active) {
        tx_byte = 512 + (byte << 1);
        tx_active = true;
    }
}

unsigned UartTx::update_tx_uart() {
    if (tx_active) {
		tx_clock = (tx_clock == 0) ? 0 : tx_clock - 1;
		if (tx_clock == 0) {
            // Transmission ended:
			init_tx_uart();
            return 1;
		} else if (tx_clock > UART_BAUDS - 1 && tx_clock % UART_BAUDS == 0) {
			// Next bit:
			shift_tx();
		} else if (tx_clock <= UART_BAUDS - 1) {
            // Stop bit
            return 1;
        }
        return tx_byte & 1;
	} else {
		return 1;
	}
}
