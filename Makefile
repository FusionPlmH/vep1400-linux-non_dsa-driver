# Build helpers for the out-of-tree vep1400 module.
#
#   make            build against the running kernel
#   make clean
#
# Installing is install.sh's job: DKMS, the systemd units, /etc/modprobe.d and
# the userspace variant all live there. See the README.

KDIR ?= /lib/modules/$(shell uname -r)/build

.PHONY: all modules clean

all: modules

modules:
	$(MAKE) -C src KDIR=$(KDIR)

clean:
	$(MAKE) -C src clean
