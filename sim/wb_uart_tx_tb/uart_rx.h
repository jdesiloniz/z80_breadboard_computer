#define UART_CHARS 10
#define UART_BAUDS 10

class UartRx {
    private:
        unsigned rx_value;
	    unsigned rx_bit_count;
	    unsigned rx_clock;
	    unsigned rx_active;
        void init_rx_uart();
        void shift_rx(unsigned rx);
    public:    
        UartRx();
        void update_rx_uart(unsigned rx);
};