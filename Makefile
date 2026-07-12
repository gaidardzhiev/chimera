#Copyright (C) 2026 Ivan Gaydardzhiev
#Licensed under the GPL-3.0-only

CC=nvcc
CFLAGS=-O2 -arch=sm_86
BIN=chimera

all: $(BIN)

$(BIN): chimera.cu
	$(CC) $(CFLAGS) -o $@ $<

clean:
	rm -f $(BIN)
