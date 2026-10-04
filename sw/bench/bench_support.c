/* Glue between the fetched benchmark sources and this platform. */
#include "rt.h"

/* riscv-tests' Dhrystone brackets its timed loop with setStats(1)/setStats(0). */
void setStats(int enable)
{
    if (enable)
        rt_stats_begin();
    else
        rt_stats_end("dhrystone");
}
