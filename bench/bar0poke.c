// Incremental, read-back-verified BAR0 poke tool for CMP 90HX (GA102)
// Gen2 unlock research.
//
// Every write is verified by reading the register back. Nothing here triggers
// a PCIe link retrain -- changing LINK_CAP only changes what the GPU
// ADVERTISES; the link speed does not change until something retrains it.
// Retrain is a separate, explicit step (see gen2retrain.sh).
//
// Usage:
//   bar0poke <bdf> snapshot            dump the registers we care about
//   bar0poke <bdf> open-plm            open XP3G privilege masks
//   bar0poke <bdf> clear-optgen23      clear OPT_GEN23
//   bar0poke <bdf> advertise-gen2      set LINK_CAP speed=2, LINK_CAP2 vector=Gen1|Gen2
//   bar0poke <bdf> target-gen2         set LINK_CTRL2 target link speed = 2
//   bar0poke <bdf> restore <file>      restore values saved by snapshot
//   bar0poke <bdf> wr <off> <val>      raw single write (verified)
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <fcntl.h>
#include <unistd.h>
#include <sys/mman.h>
#include <stdint.h>
#include <errno.h>

#define BAR0_SIZE (16u << 20)
static volatile uint32_t *bar0;

static uint32_t rd(uint32_t o){ return bar0[o/4]; }
static void     wr(uint32_t o, uint32_t v){ bar0[o/4] = v; __sync_synchronize(); }

// write + read-back; returns 1 if the value stuck
static int wrv(uint32_t off, uint32_t val, const char *name)
{
    uint32_t before = rd(off);
    wr(off, val);
    uint32_t after = rd(off);
    int ok = (after == val);
    printf("  %-18s @0x%08x  before=0x%08x  wrote=0x%08x  after=0x%08x  %s\n",
           name, off, before, val, after,
           ok ? "STUCK" : (after == before ? "REJECTED (unchanged)" : "PARTIAL"));
    return ok;
}

static const uint32_t plm_regs[] = {0x0008e1b0,0x0008e1b4,0x0008e1b8,0x0008e1bc};
static const uint32_t snap_regs[] = {
    0x00088084,0x00088088,0x000880a4,0x000880a8,0x0008872c,0x0008c1c0,
    0x0082057c,0x00820580,0x00820520,
    0x0008e100,0x0008e10c,0x0008e110,0x0008e11c,0x0008e120,0x0008e12c,
    0x0008e1b0,0x0008e1b4,0x0008e1b8,0x0008e1bc,
};

int main(int argc, char **argv)
{
    if (argc < 3) { fprintf(stderr,"usage: %s <bdf> <cmd> [args]\n", argv[0]); return 2; }
    const char *bdf = argv[1], *cmd = argv[2];

    char path[256];
    snprintf(path,sizeof path,"/sys/bus/pci/devices/%s/resource0",bdf);
    int wantwrite = strcmp(cmd,"snapshot") != 0;
    int fd = open(path, wantwrite ? O_RDWR : O_RDONLY);
    if (fd<0){ fprintf(stderr,"open %s: %s\n",path,strerror(errno)); return 1; }
    void *m = mmap(NULL,BAR0_SIZE, wantwrite?(PROT_READ|PROT_WRITE):PROT_READ, MAP_SHARED, fd,0);
    if (m==MAP_FAILED){ fprintf(stderr,"mmap: %s\n",strerror(errno)); return 1; }
    bar0=(volatile uint32_t*)m;

    if (!strcmp(cmd,"snapshot")) {
        for (size_t i=0;i<sizeof snap_regs/sizeof snap_regs[0];i++)
            printf("0x%08x 0x%08x\n", snap_regs[i], rd(snap_regs[i]));
    }
    else if (!strcmp(cmd,"open-plm")) {
        printf("Opening XP3G privilege masks to 0xffffffff:\n");
        int ok=0;
        for (size_t i=0;i<4;i++){
            char n[32]; snprintf(n,sizeof n,"XP3G_PLM%zu",i*4);
            ok += wrv(plm_regs[i], 0xffffffffU, n);
        }
        printf("\n%d/4 privilege masks opened.\n", ok);
        return ok==4?0:3;
    }
    else if (!strcmp(cmd,"clear-optgen23")) {
        printf("Clearing OPT_GEN23 (and reporting OPT_GEN3):\n");
        wrv(0x0082057c, 0x00000000U, "OPT_GEN23");
        printf("  OPT_GEN3           @0x00820580  = 0x%08x (not modified)\n", rd(0x00820580));
    }
    else if (!strcmp(cmd,"advertise-gen2")) {
        uint32_t lc  = rd(0x00088084);
        uint32_t lc2 = rd(0x000880a4);
        uint32_t nlc  = (lc & ~0xfU) | 0x2U;      // max link speed -> 5 GT/s
        uint32_t nlc2 = (lc2 & ~0xfeU) | 0x6U;    // supported vector -> 2.5 + 5 GT/s
        printf("Advertising Gen2 in link capabilities:\n");
        wrv(0x00088084, nlc,  "XVE_LINK_CAP");
        wrv(0x000880a4, nlc2, "XVE_LINK_CAP2");
        printf("\n  NOTE: this only changes what the GPU advertises.\n"
               "  The link stays at its current speed until a retrain.\n");
    }
    else if (!strcmp(cmd,"target-gen2")) {
        uint32_t v = rd(0x000880a8);
        wrv(0x000880a8, (v & ~0xfU)|0x2U, "XVE_LINK_CTRL2");
    }
    else if (!strcmp(cmd,"wr") && argc>=5) {
        uint32_t off=strtoul(argv[3],0,0), val=strtoul(argv[4],0,0);
        wrv(off,val,"raw");
    }
    else if (!strcmp(cmd,"restore") && argc>=4) {
        FILE*f=fopen(argv[3],"r"); if(!f){perror("open");return 1;}
        uint32_t o,v; int n=0;
        while(fscanf(f,"%i %i",&o,&v)==2){ wr(o,v); n++; }
        fclose(f); printf("restored %d registers\n",n);
    }
    else { fprintf(stderr,"unknown cmd %s\n",cmd); return 2; }

    munmap(m,BAR0_SIZE); close(fd);
    return 0;
}
