CC=nvcc
CFLAGS=-O2 -arch=sm_86
BIN=chimera

all: $(BIN)

$(BIN): chimera.cu
	$(CC) $(CFLAGS) -o $@ $<

clean:
	rm -f $(BIN)
