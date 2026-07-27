#Copyright (C) 2026 Ivan Gaydardzhiev
#Licensed under the GPL-3.0-only

CC=nvcc
CPUCC=cc
CPUCXX=c++
ARCH=sm_86

#Guest RAM window at 0x80000000. Must match the memory node in the dtb.
#Linux plus the busybox initramfs needs at least 16M; 32M is comfortable.
RAM_SIZE=33554432

#Leading bytes of that window shared read-only across every namespace.
#0 disables sharing and gives each namespace a private copy of the image.
#Set this to (_etext - 0x80000000) rounded down to a page to share the
#kernel text. See hacking.md.
RO_SIZE=0

DEFS=-DRAM_SIZE=$(RAM_SIZE)u -DRO_SIZE=$(RO_SIZE)u
CFLAGS=-O2 -arch=$(ARCH) $(DEFS)
CPUCFLAGS=-O2
CPUCXXFLAGS=-O2 -DCHIMERA_CPU $(DEFS)
BIN=chimera
CPUBIN=chimera-cpu
MKDTB=tools/mkdtb

all: $(BIN) $(MKDTB)

cpu: $(CPUBIN) $(MKDTB)

$(BIN): chimera.cu
	$(CC) $(CFLAGS) -o $@ $<

$(CPUBIN): chimera.cu
	$(CPUCXX) $(CPUCXXFLAGS) -x c++ -o $@ $<

$(MKDTB): tools/mkdtb.c
	$(CPUCC) $(CPUCFLAGS) -o $@ $<

clean:
	rm -f $(BIN) $(CPUBIN) $(MKDTB)

.PHONY: all cpu clean
