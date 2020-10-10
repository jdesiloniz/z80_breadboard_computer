#define UART_CHARS 10
#define UART_BAUDS 10

class UartTx {
    private:
        unsigned tx_byte;
	    unsigned tx_clock;
        void init_tx_uart();
        void shift_tx();
    public:
        UartTx();
        unsigned tx_active;
        unsigned update_tx_uart();
        void start_tx(unsigned byte);
};