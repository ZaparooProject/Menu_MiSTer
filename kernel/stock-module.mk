# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Nigel Breslaw
# Zaparoo fork: module against the reproduced September 12 stock kernel.

KERNEL_SRC ?= ../linux
KERNEL_BUILD ?= ../kernel
CROSS_COMPILE ?= arm-none-linux-gnueabihf-

obj-m += zaparoo_scanout.o

.PHONY: all qualify
all: qualify
	$(MAKE) -C $(abspath $(KERNEL_SRC)) O=$(abspath $(KERNEL_BUILD)) M=$(CURDIR) ARCH=arm CROSS_COMPILE=$(CROSS_COMPILE) LOCALVERSION=-MiSTer RUSTC=false PAHOLE=false BINDGEN=false modules

qualify:
	test "$$(git -C $(abspath $(KERNEL_SRC)) rev-parse HEAD)" = 912aa5608a4f7be881a068c36148ca1e5abb8d20
	git -C $(abspath $(KERNEL_SRC)) diff --quiet HEAD -- .
	printf '%s  %s\n' 584c7fdb7884616363b38c0514266a5fc40083ae327d9a71e72deb6f3101cdab $(abspath $(KERNEL_BUILD))/.config | sha256sum -c -
	printf '%s  %s\n' f58b220d8cdcb925afdd4ba4a4c0a04c02154a8f2fc658cc1fa885b89f79952f $(abspath $(KERNEL_BUILD))/Module.symvers | sha256sum -c -
	test "$$($(CROSS_COMPILE)gcc -dumpfullversion -dumpversion)" = 10.2.1
