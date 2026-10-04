/* Stand-in for riscv-tests' benchmarks/common/util.h: just what Dhrystone
 * uses, mapped onto this platform's runtime (sw/runtime/rt.h). */
#ifndef BENCH_UTIL_H
#define BENCH_UTIL_H

#include "rt.h"

#define read_csr(reg) ({ unsigned long v_; __asm__ volatile("csrr %0, " #reg : "=r"(v_)); v_; })

void setStats(int enable);

#endif
