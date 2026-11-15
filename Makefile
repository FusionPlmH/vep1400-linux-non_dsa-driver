# Build / install helpers for the out-of-tree vep1400 module.
#
#   make            build against the running kernel
#   make install    install the module (no DKMS)
#   make dkms       install through DKMS (Debian, Ubuntu, Proxmox VE)
#   make clean

VERSION := 2.0.0
KDIR    ?= /lib/modules/$(shell uname -r)/build
MODDIR   = /lib/modules/$(shell uname -r)/updates/dkms

.PHONY: all modules clean install dkms dkms-remove

all: modules

modules:
	$(MAKE) -C src KDIR=$(KDIR)

clean:
	$(MAKE) -C src clean

install: modules
	install -d $(MODDIR)
	install -m 0644 src/vep1400.ko $(MODDIR)/
	depmod -a $(shell uname -r)

dkms:
	install -d /usr/src/vep1400-$(VERSION)
	cp -a Makefile dkms.conf src scripts systemd modprobe README.md \
		/usr/src/vep1400-$(VERSION)/
	dkms add -m vep1400 -v $(VERSION) 2>/dev/null || true
	dkms build -m vep1400 -v $(VERSION) --force
	dkms install -m vep1400 -v $(VERSION) --force

dkms-remove:
	dkms remove -m vep1400 -v $(VERSION) --all 2>/dev/null || true
	rm -rf /usr/src/vep1400-$(VERSION)
