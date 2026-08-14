// Read-only BAR0 register peek for the CMP 90HX (GA102).
// Maps /sys/bus/pci/devices/<bdf>/resource0 and dumps named registers.
// READ ONLY unless -w is given explicitly.
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

static uint32_t rd(uint32_t off){ return bar0[off/4]; }

struct reg { uint32_t off; const char *name; const char *note; };

// Offsets taken from the 170HX (GA100) cmpunlocker patches. The whole point of
// this tool is to find out which of them mean anything on GA102.
static struct reg regs[] = {
  // --- known-good on this card: proves the mapping works ---
  {0x00823804, "FEAT_OVR_PLM",       "known-good (compute unlock opens this)"},
  {0x0082381c, "SS0",                "known-good (issue rates, 0x88888888=full)"},
  {0x00823820, "SS1",                "known-good (dp rate, 0x8=full)"},
  // --- XVE / PCIe config mirror ---
  {0x00088084, "XVE_LINK_CAP",       "PCIe Link Capabilities mirror"},
  {0x00088088, "XVE_LINK_CTRL_STAT", "Link Control/Status"},
  {0x000880a4, "XVE_LINK_CAP2",      "Link Capabilities 2"},
  {0x000880a8, "XVE_LINK_CTRL2",     "Link Control 2 (target speed)"},
  {0x0008841c, "XVE_PRIV_MISC_1",    "priv misc"},
  {0x0008860c, "XVE_VSEC_DEVICE",    "vendor-specific"},
  {0x00088610, "XVE_VSEC_HIERARCHY", "vendor-specific"},
  {0x0008872c, "XVE_LTSSM",          "link training state"},
  {0x0008c1c0, "PL_LINK_RATE",       "physical layer link rate"},
  // --- option / fuse block (same block as the working compute regs) ---
  {0x00820520, "OPT_MAGIC",          "option block magic"},
  {0x0082057c, "OPT_GEN23",          "gen2/3 enable (GA100 offset)"},
  {0x00820580, "OPT_GEN3",           "gen3 enable (GA100 offset)"},
  // --- XP3G override block ---
  {0x0008e100, "XP3G_STATUS0",       ""},
  {0x0008e10c, "XP3G_STATUS3",       ""},
  {0x0008e110, "XP3G_OVR0",          "override enable"},
  {0x0008e11c, "XP3G_OVR3",          "override enable 3"},
  {0x0008e120, "XP3G_VAL0",          "override value"},
  {0x0008e12c, "XP3G_VAL3",          "override value 3"},
  {0x0008e1b0, "XP3G_PLM",           "privilege mask"},
  {0x0008e1b4, "XP3G_PLM4",          "privilege mask"},
  {0x0008e1b8, "XP3G_PLM8",          "privilege mask"},
  {0x0008e1bc, "XP3G_PLMC",          "privilege mask"},
};

int main(int argc, char **argv)
{
    const char *bdf = (argc > 1) ? argv[1] : "0000:03:00.0";
    char path[256];
    snprintf(path, sizeof path,
             "/sys/bus/pci/devices/%s/resource0", bdf);

    int fd = open(path, O_RDONLY);
    if (fd < 0) { fprintf(stderr, "open %s: %s\n", path, strerror(errno)); return 1; }

    void *m = mmap(NULL, BAR0_SIZE, PROT_READ, MAP_SHARED, fd, 0);
    if (m == MAP_FAILED) { fprintf(stderr, "mmap: %s\n", strerror(errno)); return 1; }
    bar0 = (volatile uint32_t *)m;

    printf("BAR0 of %s mapped (%u MiB)\n\n", bdf, BAR0_SIZE >> 20);
    printf("%-10s %-20s %-12s %s\n", "OFFSET", "NAME", "VALUE", "NOTE");
    printf("%-10s %-20s %-12s %s\n", "------", "----", "-----", "----");
    for (size_t i = 0; i < sizeof regs / sizeof regs[0]; i++) {
        uint32_t v = rd(regs[i].off);
        printf("0x%08x %-20s 0x%08x   %s\n",
               regs[i].off, regs[i].name, v, regs[i].note);
    }

    // Decode the link-cap mirror the way PCIe defines it, so we can compare
    // against lspci and confirm whether this offset means anything on GA102.
    uint32_t lc = rd(0x00088084);
    printf("\n--- decode of 0x00088084 as PCIe Link Capabilities ---\n");
    printf("  raw                = 0x%08x\n", lc);
    printf("  max link speed     = %u  (1=2.5GT/s 2=5GT/s 3=8GT/s 4=16GT/s)\n", lc & 0xf);
    printf("  max link width     = %u\n", (lc >> 4) & 0x3f);
    uint32_t lc2 = rd(0x000880a8);
    printf("  LINK_CTRL2 raw     = 0x%08x  target speed = %u\n", lc2, lc2 & 0xf);

    munmap(m, BAR0_SIZE);
    close(fd);
    return 0;
}
