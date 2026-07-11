#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <cuda_runtime.h>

#define SLICE_SIZE (2 * 1024 * 1024)
#define SHARED_SIZE (64 * 1024 * 1024)
#define ENTRY_POINT 0x80000000
#define UART_BASE 0x10000000
#define UART_TX 0x00
#define UART_RX 0x00
#define UART_LSR 0x05
#define UART_LSR_DR 0x01
#define UART_LSR_THRE 0x20
#define CLINT_BASE 0x02000000
#define CLINT_MTIME 0x0000BFF8
#define CLINT_MTIMECMP 0x00004000
#define TIMER_QUANTUM 1000
#define OUTPUT_SIZE (64 * 1024)

typedef struct {
	uint32_t x[32];
	uint32_t pc;
	uint32_t mstatus;
	uint32_t mie;
	uint32_t mip;
	uint32_t mepc;
	uint32_t mcause;
	uint32_t mtvec;
	uint32_t mscratch;
	uint64_t mtime;
	uint64_t mtimecmp;
	uint32_t done;
	uint32_t status;
} cpu_t;

typedef struct {
	uint8_t mem[SLICE_SIZE];
	cpu_t cpu;
	uint8_t in[OUTPUT_SIZE];
	uint8_t out[OUTPUT_SIZE];
	uint32_t in_len;
	uint32_t in_pos;
	uint32_t out_pos;
} ns_t;

static __device__ uint32_t mem_read32(ns_t *ns, uint8_t *shared, uint32_t addr) {
	uint32_t v;
	if (addr >= ENTRY_POINT && addr < ENTRY_POINT + SHARED_SIZE) {
		memcpy(&v, shared + (addr - ENTRY_POINT), 4);
		return v;
	}
	if (addr < SLICE_SIZE) {
		memcpy(&v, ns->mem + addr, 4);
		return v;
	}
	return 0;
}

static __device__ uint8_t mem_read8(ns_t *ns, uint8_t *shared, uint32_t addr) {
	if (addr >= ENTRY_POINT && addr < ENTRY_POINT + SHARED_SIZE)
		return shared[addr - ENTRY_POINT];
	if (addr < SLICE_SIZE)
		return ns->mem[addr];
	return 0;
}

static __device__ void mem_write32(ns_t *ns, uint32_t addr, uint32_t val) {
	if (addr >= ENTRY_POINT && addr < ENTRY_POINT + SHARED_SIZE) {
		ns->cpu.done = 1;
		ns->cpu.status = 1;
		return;
	}
	if (addr < SLICE_SIZE) {
		memcpy(ns->mem + addr, &val, 4);
		return;
	}
}

static __device__ void mem_write8(ns_t *ns, uint32_t addr, uint8_t val) {
	if (addr >= ENTRY_POINT && addr < ENTRY_POINT + SHARED_SIZE) {
		ns->cpu.done = 1;
		ns->cpu.status = 1;
		return;
	}
	if (addr < SLICE_SIZE) {
		ns->mem[addr] = val;
		return;
	}
}

static __device__ uint32_t mmio_read(ns_t *ns, uint32_t addr) {
	uint32_t off;
	if (addr >= UART_BASE && addr < UART_BASE + 0x100) {
		off = addr - UART_BASE;
		switch (off) {
		case UART_RX:
			if (ns->in_pos < ns->in_len)
				return ns->in[ns->in_pos++];
			return 0;
		case UART_LSR:
			return UART_LSR_THRE |
				(ns->in_pos < ns->in_len ? UART_LSR_DR : 0);
		}
		return 0;
	}
	if (addr >= CLINT_BASE && addr < CLINT_BASE + 0x10000) {
		off = addr - CLINT_BASE;
		switch (off) {
		case CLINT_MTIME:
			return (uint32_t)(ns->cpu.mtime & 0xffffffff);
		case CLINT_MTIME + 4:
			return (uint32_t)(ns->cpu.mtime >> 32);
		case CLINT_MTIMECMP:
			return (uint32_t)(ns->cpu.mtimecmp & 0xffffffff);
		case CLINT_MTIMECMP + 4:
			return (uint32_t)(ns->cpu.mtimecmp >> 32);
		}
		return 0;
	}
	return 0;
}

static __device__ void mmio_write(ns_t *ns, uint32_t addr, uint32_t val) {
	uint32_t off;
	if (addr >= UART_BASE && addr < UART_BASE + 0x100) {
		off = addr - UART_BASE;
		if (off == UART_TX && ns->out_pos < OUTPUT_SIZE)
			ns->out[ns->out_pos++] = (uint8_t)val;
		return;
	}
	if (addr >= CLINT_BASE && addr < CLINT_BASE + 0x10000) {
		off = addr - CLINT_BASE;
		switch (off) {
		case CLINT_MTIMECMP:
			ns->cpu.mtimecmp =
				(ns->cpu.mtimecmp & 0xffffffff00000000ULL) | val;
			break;
		case CLINT_MTIMECMP + 4:
			ns->cpu.mtimecmp =
				(ns->cpu.mtimecmp & 0x00000000ffffffffULL) |
				((uint64_t)val << 32);
			break;
		}
		return;
	}
}

static __device__ int is_mmio(uint32_t addr) {
	return (addr >= UART_BASE && addr < UART_BASE + 0x100) ||
		(addr >= CLINT_BASE && addr < CLINT_BASE + 0x10000);
}

static __device__ void timer_tick(ns_t *ns) {
	ns->cpu.mtime += TIMER_QUANTUM;
	if (ns->cpu.mtime >= ns->cpu.mtimecmp)
		ns->cpu.mip |= (1 << 7);
}

static __device__ void interrupt_check(ns_t *ns) {
	if (!(ns->cpu.mstatus & 0x8))
		return;
	if (!(ns->cpu.mie & ns->cpu.mip))
		return;
	ns->cpu.mepc = ns->cpu.pc;
	ns->cpu.mcause = 0x80000007;
	ns->cpu.mstatus &= ~0x8;
	ns->cpu.mip &= ~(1 << 7);
	ns->cpu.pc = ns->cpu.mtvec & ~0x3;
}

static __device__ void csr_write(ns_t *ns, uint32_t csr, uint32_t val) {
	switch (csr) {
	case 0x300: ns->cpu.mstatus = val; break;
	case 0x304: ns->cpu.mie = val; break;
	case 0x305: ns->cpu.mtvec = val; break;
	case 0x340: ns->cpu.mscratch = val; break;
	case 0x341: ns->cpu.mepc = val; break;
	case 0x342: ns->cpu.mcause = val; break;
	case 0x344: ns->cpu.mip = val; break;
	}
}

static __device__ uint32_t csr_read(ns_t *ns, uint32_t csr) {
	switch (csr) {
	case 0x300: return ns->cpu.mstatus;
	case 0x304: return ns->cpu.mie;
	case 0x305: return ns->cpu.mtvec;
	case 0x340: return ns->cpu.mscratch;
	case 0x341: return ns->cpu.mepc;
	case 0x342: return ns->cpu.mcause;
	case 0x344: return ns->cpu.mip;
	}
	return 0;
}

static __device__ void fetch_decode_execute(ns_t *ns, uint8_t *shared) {
	uint32_t ir, op, rd, rs1, rs2, funct3, funct7;
	uint32_t imm, addr, val, old;
	int32_t simm;
	ir = mem_read32(ns, shared, ns->cpu.pc);
	op = ir & 0x7f;
	rd = (ir >> 7) & 0x1f;
	funct3 = (ir >> 12) & 0x07;
	rs1 = (ir >> 15) & 0x1f;
	rs2 = (ir >> 20) & 0x1f;
	funct7 = (ir >> 25) & 0x7f;
	ns->cpu.x[0] = 0;
	ns->cpu.pc += 4;
	switch (op) {
	case 0x37:
		if (rd)
			ns->cpu.x[rd] = ir & 0xfffff000;
		break;
	case 0x17:
		if (rd)
			ns->cpu.x[rd] = (ns->cpu.pc - 4) + (ir & 0xfffff000);
		break;
	case 0x6f:
		imm = ((ir >> 31) & 1) << 20 |
			((ir >> 12) & 0xff) << 12 |
			((ir >> 20) & 1) << 11 |
			((ir >> 21) & 0x3ff) << 1;
		if (imm & (1 << 20))
			imm |= 0xffe00000;
		if (rd)
			ns->cpu.x[rd] = ns->cpu.pc;
		ns->cpu.pc = (ns->cpu.pc - 4) + imm;
		break;
	case 0x67:
		simm = (int32_t)ir >> 20;
		val = ns->cpu.pc;
		ns->cpu.pc = (ns->cpu.x[rs1] + simm) & ~1;
		if (rd)
			ns->cpu.x[rd] = val;
		break;
	case 0x63:
		imm = ((ir >> 31) & 1) << 12 |
			((ir >> 7) & 1) << 11 |
			((ir >> 25) & 0x3f) << 5 |
			((ir >> 8) & 0xf) << 1;
		if (imm & (1 << 12))
			imm |= 0xffffe000;
		switch (funct3) {
		case 0x0:
			if (ns->cpu.x[rs1] == ns->cpu.x[rs2])
				ns->cpu.pc = (ns->cpu.pc - 4) + imm;
			break;
		case 0x1:
			if (ns->cpu.x[rs1] != ns->cpu.x[rs2])
				ns->cpu.pc = (ns->cpu.pc - 4) + imm;
			break;
		case 0x4:
			if ((int32_t)ns->cpu.x[rs1] < (int32_t)ns->cpu.x[rs2])
				ns->cpu.pc = (ns->cpu.pc - 4) + imm;
			break;
		case 0x5:
			if ((int32_t)ns->cpu.x[rs1] >= (int32_t)ns->cpu.x[rs2])
				ns->cpu.pc = (ns->cpu.pc - 4) + imm;
			break;
		case 0x6:
			if (ns->cpu.x[rs1] < ns->cpu.x[rs2])
				ns->cpu.pc = (ns->cpu.pc - 4) + imm;
			break;
		case 0x7:
			if (ns->cpu.x[rs1] >= ns->cpu.x[rs2])
				ns->cpu.pc = (ns->cpu.pc - 4) + imm;
			break;
		}
		break;
	case 0x03:
		simm = (int32_t)ir >> 20;
		addr = ns->cpu.x[rs1] + simm;
		switch (funct3) {
		case 0x0:
			val = is_mmio(addr) ? mmio_read(ns, addr) : mem_read8(ns, shared, addr);
			if (rd) ns->cpu.x[rd] = (int32_t)(int8_t)val;
			break;
		case 0x1:
			val = is_mmio(addr) ? mmio_read(ns, addr) : mem_read32(ns, shared, addr);
			if (rd) ns->cpu.x[rd] = (int32_t)(int16_t)val;
			break;
		case 0x2:
			val = is_mmio(addr) ? mmio_read(ns, addr) : mem_read32(ns, shared, addr);
			if (rd) ns->cpu.x[rd] = val;
			break;
		case 0x4:
			val = is_mmio(addr) ? mmio_read(ns, addr) : mem_read8(ns, shared, addr);
			if (rd) ns->cpu.x[rd] = val;
			break;
		case 0x5:
			val = is_mmio(addr) ? mmio_read(ns, addr) : mem_read32(ns, shared, addr);
			if (rd) ns->cpu.x[rd] = (uint16_t)val;
			break;
		}
		break;
	case 0x23:
		imm = ((ir >> 25) & 0x7f) << 5 | ((ir >> 7) & 0x1f);
		if (imm & (1 << 11))
			imm |= 0xfffff000;
		addr = ns->cpu.x[rs1] + imm;
		switch (funct3) {
		case 0x0:
			if (is_mmio(addr)) mmio_write(ns, addr, ns->cpu.x[rs2]);
			else mem_write8(ns, addr, ns->cpu.x[rs2]);
			break;
		case 0x1:
		case 0x2:
			if (is_mmio(addr)) mmio_write(ns, addr, ns->cpu.x[rs2]);
			else mem_write32(ns, addr, ns->cpu.x[rs2]);
			break;
		}
		break;
	case 0x13:
		simm = (int32_t)ir >> 20;
		switch (funct3) {
		case 0x0:
			if (rd) ns->cpu.x[rd] = ns->cpu.x[rs1] + simm;
			break;
		case 0x1:
			if (rd) ns->cpu.x[rd] = ns->cpu.x[rs1] << (rs2 & 0x1f);
			break;
		case 0x2:
			if (rd) ns->cpu.x[rd] = (int32_t)ns->cpu.x[rs1] < simm ? 1 : 0;
			break;
		case 0x3:
			if (rd) ns->cpu.x[rd] = ns->cpu.x[rs1] < (uint32_t)simm ? 1 : 0;
			break;
		case 0x4:
			if (rd) ns->cpu.x[rd] = ns->cpu.x[rs1] ^ simm;
			break;
		case 0x5:
			if (funct7 == 0x20) {
				if (rd) ns->cpu.x[rd] = (int32_t)ns->cpu.x[rs1] >> (rs2 & 0x1f);
			} else {
				if (rd) ns->cpu.x[rd] = ns->cpu.x[rs1] >> (rs2 & 0x1f);
			}
			break;
		case 0x6:
			if (rd) ns->cpu.x[rd] = ns->cpu.x[rs1] | simm;
			break;
		case 0x7:
			if (rd) ns->cpu.x[rd] = ns->cpu.x[rs1] & simm;
			break;
		}
		break;
	case 0x33:
		switch (funct3) {
		case 0x0:
			if (funct7 == 0x20) {
				if (rd) ns->cpu.x[rd] = ns->cpu.x[rs1] - ns->cpu.x[rs2];
			} else if (funct7 == 0x01) {
				if (rd) ns->cpu.x[rd] = (int32_t)ns->cpu.x[rs1] * (int32_t)ns->cpu.x[rs2];
			} else {
				if (rd) ns->cpu.x[rd] = ns->cpu.x[rs1] + ns->cpu.x[rs2];
			}
			break;
		case 0x1:
			if (funct7 == 0x01) {
				int64_t a = (int64_t)(int32_t)ns->cpu.x[rs1] * (int32_t)ns->cpu.x[rs2];
				if (rd) ns->cpu.x[rd] = (uint32_t)(a >> 32);
			} else {
				if (rd) ns->cpu.x[rd] = ns->cpu.x[rs1] << (ns->cpu.x[rs2] & 0x1f);
			}
			break;
		case 0x2:
			if (funct7 == 0x01) {
				int64_t a = (int64_t)(int32_t)ns->cpu.x[rs1] * (uint64_t)ns->cpu.x[rs2];
				if (rd) ns->cpu.x[rd] = (uint32_t)(a >> 32);
			} else {
				if (rd) ns->cpu.x[rd] = (int32_t)ns->cpu.x[rs1] < (int32_t)ns->cpu.x[rs2] ? 1 : 0;
			}
			break;
		case 0x3:
			if (funct7 == 0x01) {
				uint64_t a = (uint64_t)ns->cpu.x[rs1] * (uint64_t)ns->cpu.x[rs2];
				if (rd) ns->cpu.x[rd] = (uint32_t)(a >> 32);
			} else {
				if (rd) ns->cpu.x[rd] = ns->cpu.x[rs1] < ns->cpu.x[rs2] ? 1 : 0;
			}
			break;
		case 0x4:
			if (funct7 == 0x01) {
				if (ns->cpu.x[rs2] == 0) {
					if (rd) ns->cpu.x[rd] = -1;
				} else {
					if (rd) ns->cpu.x[rd] = (int32_t)ns->cpu.x[rs1] / (int32_t)ns->cpu.x[rs2];
				}
			} else {
				if (rd) ns->cpu.x[rd] = ns->cpu.x[rs1] ^ ns->cpu.x[rs2];
			}
			break;
		case 0x5:
			if (funct7 == 0x01) {
				if (ns->cpu.x[rs2] == 0) {
					if (rd) ns->cpu.x[rd] = 0xffffffff;
				} else {
					if (rd) ns->cpu.x[rd] = ns->cpu.x[rs1] / ns->cpu.x[rs2];
				}
			} else if (funct7 == 0x20) {
				if (rd) ns->cpu.x[rd] = (int32_t)ns->cpu.x[rs1] >> (ns->cpu.x[rs2] & 0x1f);
			} else {
				if (rd) ns->cpu.x[rd] = ns->cpu.x[rs1] >> (ns->cpu.x[rs2] & 0x1f);
			}
			break;
		case 0x6:
			if (funct7 == 0x01) {
				if (ns->cpu.x[rs2] == 0) {
					if (rd) ns->cpu.x[rd] = ns->cpu.x[rs1];
				} else {
					if (rd) ns->cpu.x[rd] = (int32_t)ns->cpu.x[rs1] % (int32_t)ns->cpu.x[rs2];
				}
			} else {
				if (rd) ns->cpu.x[rd] = ns->cpu.x[rs1] | ns->cpu.x[rs2];
			}
			break;
		case 0x7:
			if (funct7 == 0x01) {
				if (ns->cpu.x[rs2] == 0) {
					if (rd) ns->cpu.x[rd] = ns->cpu.x[rs1];
				} else {
					if (rd) ns->cpu.x[rd] = ns->cpu.x[rs1] % ns->cpu.x[rs2];
				}
			} else {
				if (rd) ns->cpu.x[rd] = ns->cpu.x[rs1] & ns->cpu.x[rs2];
			}
			break;
		}
		break;
	case 0x2f:
		if (rd) ns->cpu.x[rd] = mem_read32(ns, shared, ns->cpu.x[rs1]);
		if (funct3 == 0x2 && funct7 >> 2 == 0x03)
			mem_write32(ns, ns->cpu.x[rs1], ns->cpu.x[rs2]);
		break;
	case 0x73:
		switch (funct3) {
		case 0x0:
			switch (ir >> 20) {
			case 0x000:
				ns->cpu.done = 1;
				ns->cpu.status = ns->cpu.x[10];
				break;
			case 0x001:
				ns->cpu.mepc = ns->cpu.pc;
				ns->cpu.mstatus &= ~0x8;
				ns->cpu.pc = ns->cpu.mtvec & ~0x3;
				break;
			case 0x302:
				ns->cpu.pc = ns->cpu.mepc;
				ns->cpu.mstatus |= 0x8;
				break;
			}
			break;
		case 0x1:
			old = csr_read(ns, ir >> 20);
			csr_write(ns, ir >> 20, ns->cpu.x[rs1]);
			if (rd) ns->cpu.x[rd] = old;
			break;
		case 0x2:
			old = csr_read(ns, ir >> 20);
			csr_write(ns, ir >> 20, old | ns->cpu.x[rs1]);
			if (rd) ns->cpu.x[rd] = old;
			break;
		case 0x3:
			old = csr_read(ns, ir >> 20);
			csr_write(ns, ir >> 20, old & ~ns->cpu.x[rs1]);
			if (rd) ns->cpu.x[rd] = old;
			break;
		case 0x5:
			old = csr_read(ns, ir >> 20);
			csr_write(ns, ir >> 20, rs1);
			if (rd) ns->cpu.x[rd] = old;
			break;
		case 0x6:
			old = csr_read(ns, ir >> 20);
			csr_write(ns, ir >> 20, old | rs1);
			if (rd) ns->cpu.x[rd] = old;
			break;
		case 0x7:
			old = csr_read(ns, ir >> 20);
			csr_write(ns, ir >> 20, old & ~rs1);
			if (rd) ns->cpu.x[rd] = old;
			break;
		}
		break;
	default:
		ns->cpu.done = 1;
		ns->cpu.status = 2;
		break;
	}
}

__global__ void chimera(ns_t *namespaces, uint8_t *shared, uint32_t n) {
	uint32_t tid = blockIdx.x * blockDim.x + threadIdx.x;
	ns_t *ns;
	if (tid >= n)
		return;
	ns = &namespaces[tid];
	ns->cpu.pc = ENTRY_POINT;
	while (!ns->cpu.done) {
		timer_tick(ns);
		interrupt_check(ns);
		fetch_decode_execute(ns, shared);
	}
}

static void die(const char *msg) {
	fprintf(stderr, "%s\n", msg);
	exit(1);
}

static void cuda_check(cudaError_t e, const char *msg) {
	if (e != cudaSuccess) {
		fprintf(stderr, "%s: %s\n", msg, cudaGetErrorString(e));
		exit(1);
	}
}

static void load_binary(uint8_t *dst, const char *path) {
	FILE *f;
	long sz;
	uint8_t *buf;
	f = fopen(path, "rb");
	if (!f) die("cannot open binary");
	fseek(f, 0, SEEK_END);
	sz = ftell(f);
	rewind(f);
	buf = (uint8_t *)malloc(sz);
	if (!buf) die("malloc failed");
	fread(buf, 1, sz, f);
	fclose(f);
	memcpy(dst, buf, sz);
	free(buf);
}

int main(int argc, char **argv) {
	uint32_t n, blocks, threads, i;
	ns_t *d_ns, *h_ns;
	uint8_t *d_shared, *h_shared;
	if (argc < 3) {
		fprintf(stderr, "usage: %s <binary.bin> <n>\n", argv[0]);
		return 1;
	}
	n = (uint32_t)atoi(argv[2]);
	if (!n) die("n must be > 0");
	h_shared = (uint8_t *)calloc(1, SHARED_SIZE);
	if (!h_shared) die("calloc shared failed");
	load_binary(h_shared, argv[1]);
	h_ns = (ns_t *)calloc(n, sizeof(ns_t));
	if (!h_ns) die("calloc ns failed");
	for (i = 0; i < n; i++) {
		h_ns[i].cpu.mtimecmp = UINT64_MAX;
		h_ns[i].in_len = 0;
		h_ns[i].in_pos = 0;
		h_ns[i].out_pos = 0;
	}
	cuda_check(cudaMalloc(&d_shared, SHARED_SIZE), "cudaMalloc shared");
	cuda_check(cudaMalloc(&d_ns, n * sizeof(ns_t)), "cudaMalloc ns");
	cuda_check(cudaMemcpy(d_shared, h_shared, SHARED_SIZE, cudaMemcpyHostToDevice), "memcpy shared");
	cuda_check(cudaMemcpy(d_ns, h_ns, n * sizeof(ns_t), cudaMemcpyHostToDevice), "memcpy ns");
	threads = 256;
	blocks = (n + threads - 1) / threads;
	chimera<<<blocks, threads>>>(d_ns, d_shared, n);
	cuda_check(cudaDeviceSynchronize(), "sync");
	cuda_check(cudaMemcpy(h_ns, d_ns, n * sizeof(ns_t), cudaMemcpyDeviceToHost), "memcpy back");
	for (i = 0; i < n; i++) {
		if (h_ns[i].out_pos)
			fwrite(h_ns[i].out, 1, h_ns[i].out_pos, stdout);
	}
	cudaFree(d_shared);
	cudaFree(d_ns);
	free(h_shared);
	free(h_ns);
	return 0;
}
