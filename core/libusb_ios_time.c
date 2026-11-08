// iOS: libusb's Darwin backend (which defines these on Apple platforms) is not built; the null
// backend still needs the clock functions declared in libusbi.h.
#include "libusbi.h"

#include <time.h>

void usbi_get_monotonic_time(struct timespec *tp)
{
	clock_gettime(CLOCK_MONOTONIC, tp);
}

void usbi_get_real_time(struct timespec *tp)
{
	clock_gettime(CLOCK_REALTIME, tp);
}
