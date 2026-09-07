obj-m += cmp_no_bus_reset.o

KVER ?= $(shell uname -r)

all:
	$(MAKE) -C /lib/modules/$(KVER)/build M=$(CURDIR) modules

clean:
	$(MAKE) -C /lib/modules/$(KVER)/build M=$(CURDIR) clean
