# SPDX-License-Identifier: GPL-2.0
#
# One module, two objects: the 88E6190 / front panel part and the board I2C
# part (PIC watchdog, SFP TX).

obj-m := vep1400.o
vep1400-y := vep1400_switch.o vep1400_board.o

KDIR ?= /lib/modules/$(shell uname -r)/build
PWD  := $(shell pwd)

all:
	$(MAKE) -C $(KDIR) M=$(PWD) modules

clean:
	$(MAKE) -C $(KDIR) M=$(PWD) clean

.PHONY: all clean
