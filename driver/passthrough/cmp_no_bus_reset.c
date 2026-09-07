// SPDX-License-Identifier: MIT
#include <linux/module.h>
#include <linux/pci.h>

#define CMP_MAX_DEVS 8

static char *devs[CMP_MAX_DEVS];
static int ndevs;
module_param_array(devs, charp, &ndevs, 0444);
MODULE_PARM_DESC(devs, "PCI addresses, e.g. devs=0000:04:00.0");

static struct pci_dev *held[CMP_MAX_DEVS];
static int nheld;

static void cmp_nbr_release(void)
{
	int i;

	for (i = 0; i < nheld; i++) {
		if (held[i]) {
			held[i]->dev_flags &= ~PCI_DEV_FLAGS_NO_BUS_RESET;
			pci_info(held[i], "cmp_no_bus_reset: NO_BUS_RESET cleared\n");
			pci_dev_put(held[i]);
			held[i] = NULL;
		}
	}
	nheld = 0;
}

static int __init cmp_nbr_init(void)
{
	unsigned int dom, bus, slot, fn;
	struct pci_dev *pdev;
	int i;

	if (ndevs <= 0) {
		pr_err("cmp_no_bus_reset: no devs= given\n");
		return -EINVAL;
	}

	for (i = 0; i < ndevs; i++) {
		if (sscanf(devs[i], "%x:%x:%x.%x", &dom, &bus, &slot, &fn) != 4) {
			pr_err("cmp_no_bus_reset: bad address %s\n", devs[i]);
			cmp_nbr_release();
			return -EINVAL;
		}

		pdev = pci_get_domain_bus_and_slot(dom, bus, PCI_DEVFN(slot, fn));
		if (!pdev) {
			pr_err("cmp_no_bus_reset: %s not found\n", devs[i]);
			cmp_nbr_release();
			return -ENODEV;
		}

		if (pdev->vendor != 0x10de ||
		    (pdev->device != 0x20c2 && pdev->device != 0x2082)) {
			pci_err(pdev, "cmp_no_bus_reset: not a CMP 170HX (%04x:%04x)\n",
				pdev->vendor, pdev->device);
			pci_dev_put(pdev);
			cmp_nbr_release();
			return -ENODEV;
		}

		pdev->dev_flags |= PCI_DEV_FLAGS_NO_BUS_RESET;
		held[nheld++] = pdev;
		pci_info(pdev, "cmp_no_bus_reset: NO_BUS_RESET set\n");
	}

	return 0;
}

static void __exit cmp_nbr_exit(void)
{
	cmp_nbr_release();
}

module_init(cmp_nbr_init);
module_exit(cmp_nbr_exit);
MODULE_LICENSE("GPL");
MODULE_DESCRIPTION("Block secondary bus reset on CMP 170HX for VFIO passthrough");
