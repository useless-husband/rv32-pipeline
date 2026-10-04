/* alloca for the bare-metal benchmarks (Dhrystone allocates its records with it). */
#ifndef ALLOCA_H
#define ALLOCA_H
#define alloca(n) __builtin_alloca(n)
#endif
