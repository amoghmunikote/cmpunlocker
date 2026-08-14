// Read-only scan for privilege-mask (PLM) registers near the blocks that gate
// the PCIe Gen2 path on GA102. PLM registers characteristically read as
// 0xffffffXX / 0x00000000-with-high-bits patterns and cluster at the end of a
// register block. We just want to know which masks exist and which are OPEN.
#include <stdio.h>
#include <stdlib.h>
#include <fcntl.h>
#include <unistd.h>
#include <sys/mman.h>
#include <stdint.h>
#include <string.h>
#include <errno.h>

#define BAR0_SIZE (16u<<20)
static volatile uint32_t *bar0;
static uint32_t rd(uint32_t o){ return bar0[o/4]; }

struct range { uint32_t lo, hi; const char *name; };

static struct range ranges[] = {
    {0x00088000, 0x00088800, "XVE (PCIe config mirror)"},
    {0x0008e000, 0x0008e200, "XP3G (link override block)"},
    {0x0008c100, 0x0008c200, "PL (physical layer)"},
    {0x00820500, 0x00820600, "OPT (option/fuse block)"},
    {0x00823800, 0x00823900, "compute throttle block (known-good)"},
};

// Heuristic: a PLM-looking value has most high bits set.
static int plm_like(uint32_t v)
{
    if (v == 0xffffffffU) return 1;
    // 0xffffffXX with at least the top 24 bits set
    if ((v & 0xffffff00U) == 0xffffff00U) return 1;
    return 0;
}

int main(int argc, char**argv)
{
    const char *bdf = argc>1?argv[1]:"0000:03:00.0";
    char p[256]; snprintf(p,sizeof p,"/sys/bus/pci/devices/%s/resource0",bdf);
    int fd=open(p,O_RDONLY);
    if(fd<0){fprintf(stderr,"open: %s\n",strerror(errno));return 1;}
    void*m=mmap(NULL,BAR0_SIZE,PROT_READ,MAP_SHARED,fd,0);
    if(m==MAP_FAILED){fprintf(stderr,"mmap: %s\n",strerror(errno));return 1;}
    bar0=(volatile uint32_t*)m;

    for (size_t r=0; r<sizeof ranges/sizeof ranges[0]; r++) {
        printf("\n=== %s  [0x%08x - 0x%08x] ===\n",
               ranges[r].name, ranges[r].lo, ranges[r].hi);
        int found=0;
        for (uint32_t o=ranges[r].lo; o<ranges[r].hi; o+=4) {
            uint32_t v = rd(o);
            if (plm_like(v)) {
                const char *state =
                    (v==0xffffffffU) ? "OPEN (all levels permitted)"
                                     : "RESTRICTED";
                printf("  0x%08x = 0x%08x   %s\n", o, v, state);
                found++;
            }
        }
        if(!found) printf("  (no PLM-like registers found)\n");
    }
    munmap(m,BAR0_SIZE); close(fd);
    return 0;
}
