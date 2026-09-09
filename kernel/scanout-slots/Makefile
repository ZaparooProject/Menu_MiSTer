# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Nigel Breslaw
# Zaparoo fork: local builds against the qualified MiSTer kernel.

KERNEL_SRC ?= ../.build/linux-6.18
KERNEL_BUILD ?= ../.build/kernel-6.18
ARCH ?= arm
CROSS_COMPILE ?= arm-none-linux-gnueabihf-
LOCALVERSION ?= -MiSTer

obj-m += zaparoo_scanout.o

.PHONY: all qualify clean
all: qualify
	$(MAKE) -C $(abspath $(KERNEL_SRC)) O=$(abspath $(KERNEL_BUILD)) M=$(CURDIR) ARCH=$(ARCH) CROSS_COMPILE=$(CROSS_COMPILE) LOCALVERSION=$(LOCALVERSION) modules

# Pin source/config as well as vermagic; never bless a different 6.18 build.
qualify:
	test "$(ARCH)" = arm
	test "$(LOCALVERSION)" = -MiSTer
	test "$$(git -C $(abspath $(KERNEL_SRC)) rev-parse HEAD)" = aec7dc3aa4846385736f1d54c9155e3b3c726708
	git -C $(abspath $(KERNEL_SRC)) diff --quiet HEAD -- .
	printf '%s  %s\n' 0d010a3d551cbffcd91af7850f3f745ce73f3bb911cfd56ead902fc9b6c69823 $(abspath $(KERNEL_BUILD))/.config | sha256sum -c -
	test -s $(abspath $(KERNEL_BUILD))/Module.symvers
	test "$$($(CROSS_COMPILE)gcc -dumpfullversion -dumpversion)" = 10.2.1

clean:
	$(MAKE) -C $(abspath $(KERNEL_SRC)) O=$(abspath $(KERNEL_BUILD)) M=$(CURDIR) ARCH=$(ARCH) CROSS_COMPILE=$(CROSS_COMPILE) LOCALVERSION=$(LOCALVERSION) clean
