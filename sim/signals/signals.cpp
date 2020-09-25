#include "signals.h"

bool signal_rose(unsigned last, unsigned current) {
	return (last == 0 && current == 1);
}

bool signal_fell(unsigned last, unsigned current) {
	return (last == 1 && current == 0);
}

bool signal_stayed(unsigned last, unsigned current, unsigned value) {
	return (last == value && current == value);
}