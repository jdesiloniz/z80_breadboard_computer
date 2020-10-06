#include <stdio.h>
#include "uart_rx.h"

UartRx::UartRx()
{
    init_rx_uart();
}

void UartRx::init_rx_uart() {
    rx_value = 0;
	rx_char_count = 0;
	rx_clock = (UART_CHARS * (UART_BAUDS - 1));
	rx_active = false;
}

void UartRx::shift_rx(unsigned rx) {
    rx_value = (rx_value + (rx << rx_char_count));
}

void UartRx::update_rx_uart(unsigned rx) {
    if (rx_active) {
		rx_clock = (rx_clock == 0) ? 0 : rx_clock - 1;
		if (rx_clock == 0) {
			shift_rx(rx);
			// UART tx stopped:
			unsigned final_value = (rx_value >> 1) & 255;
			printf("%c", final_value);

			init_rx_uart();
		} else if (rx_clock > 0 && rx_clock % UART_BAUDS == 0) {
			// A new bit was sent:
			shift_rx(rx);
			rx_char_count++;
		}
	} else if (rx == 0) {
		rx_active = true;
	}
}
