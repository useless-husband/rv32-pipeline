/* Smallest demo: print a line and a few numbers, then exit(0). */
#include "rt.h"

int main(void)
{
    printf("hello from rv32 (%d + %d = %d, 0x%08x)\n", 40, 2, 40 + 2, 0xC0FFEEu);
    return 0;
}
