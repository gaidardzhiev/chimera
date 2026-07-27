/*
 * Copyright (C) 2026 Ivan Gaydardzhiev
 * Licensed under the GPL-3.0-only
 *
 * mkdtb.c - generate a minimal flattened device tree for the Chimera
 * virtual machine. Describes exactly the four devices the emulator
 * implements: one RV32IMA CPU, memory at 0x80000000, NS16550 UART at
 * 0x10000000, and CLINT at 0x02000000. No other devices are described.
 * The kernel initializes only what is listed here and nothing else.
 *
 * usage: mkdtb <initrd_start> <initrd_end> <cmdline> <output.dtb>
 *            [ram_size_hex] [timebase_hz]
 *
 * initrd_start and initrd_end are physical addresses in hex without 0x prefix.
 * ram_size defaults to 0x02000000 and must match RAM_SIZE in chimera.cu.
 * timebase defaults to 10000000 and must match the rate at which the
 * emulator advances mtime: TIMER_QUANTUM ticks per retired instruction.
 */

#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define FDT_MAGIC       0xd00dfeed
#define FDT_BEGIN_NODE  0x00000001
#define FDT_END_NODE    0x00000002
#define FDT_PROP        0x00000003
#define FDT_NOP         0x00000004
#define FDT_END         0x00000009

#define MAX_DTB (8 * 1024)

static uint8_t buf[MAX_DTB];
static uint32_t pos;
static uint8_t sbuf[MAX_DTB];
static uint32_t spos;

static void w32(uint32_t v) {
	buf[pos++] = (v >> 24) & 0xff;
	buf[pos++] = (v >> 16) & 0xff;
	buf[pos++] = (v >>  8) & 0xff;
	buf[pos++] = (v >>  0) & 0xff;
}

static uint32_t str_off(const char *s) {
	uint32_t i;
	uint32_t len = (uint32_t)strlen(s) + 1;
	for (i = 0; i < spos; i++) {
		if (memcmp(sbuf + i, s, len) == 0)
			return i;
	}
	i = spos;
	memcpy(sbuf + spos, s, len);
	spos += len;
	return i;
}

static void begin_node(const char *name) {
	uint32_t len, pad;
	w32(FDT_BEGIN_NODE);
	len = (uint32_t)strlen(name) + 1;
	memcpy(buf + pos, name, len);
	pos += len;
	pad = (4 - (pos & 3)) & 3;
	while (pad--) buf[pos++] = 0;
}

static void end_node(void) {
	w32(FDT_END_NODE);
}

static void prop(const char *name, const void *data, uint32_t dlen) {
	uint32_t pad;
	w32(FDT_PROP);
	w32(dlen);
	w32(str_off(name));
	if (dlen) {
		memcpy(buf + pos, data, dlen);
		pos += dlen;
	}
	pad = (4 - (pos & 3)) & 3;
	while (pad--) buf[pos++] = 0;
}

static void prop_u32(const char *name, uint32_t v) {
	uint8_t d[4];
	d[0] = (v >> 24) & 0xff;
	d[1] = (v >> 16) & 0xff;
	d[2] = (v >>  8) & 0xff;
	d[3] = (v >>  0) & 0xff;
	prop(name, d, 4);
}

static void prop_u64(const char *name, uint64_t v) {
	uint8_t d[8];
	d[0] = (v >> 56) & 0xff;
	d[1] = (v >> 48) & 0xff;
	d[2] = (v >> 40) & 0xff;
	d[3] = (v >> 32) & 0xff;
	d[4] = (v >> 24) & 0xff;
	d[5] = (v >> 16) & 0xff;
	d[6] = (v >>  8) & 0xff;
	d[7] = (v >>  0) & 0xff;
	prop(name, d, 8);
}

static void prop_str(const char *name, const char *s) {
	prop(name, s, (uint32_t)strlen(s) + 1);
}

static void prop_empty(const char *name) {
	prop(name, NULL, 0);
}

static void prop_reg32(const char *name, uint32_t base, uint32_t size) {
	uint8_t d[8];
	d[0] = (base >> 24) & 0xff;
	d[1] = (base >> 16) & 0xff;
	d[2] = (base >>  8) & 0xff;
	d[3] = (base >>  0) & 0xff;
	d[4] = (size >> 24) & 0xff;
	d[5] = (size >> 16) & 0xff;
	d[6] = (size >>  8) & 0xff;
	d[7] = (size >>  0) & 0xff;
	prop(name, d, 8);
}

int main(int argc, char **argv) {
	uint32_t struct_off, strings_off, total_size, struct_size;
	uint32_t hdr_size = 10 * 4;
	uint32_t rsv_off = hdr_size;
	uint32_t ram_size = 0x02000000;
	uint32_t timebase = 10000000;
	uint32_t initrd_start, initrd_end;
	const char *cmdline;
	const char *outpath;
	FILE *f;
	uint8_t clint_reg[16];
	uint8_t uart_intr[8];
	uint8_t clint_intr[16];

	if (argc < 5 || argc > 7) {
		fprintf(stderr,
			"usage: %s <initrd_start_hex> <initrd_end_hex> <cmdline> <out.dtb>"
			" [ram_size_hex] [timebase_hz]\n",
			argv[0]);
		return 1;
	}
	if (argc >= 6)
		ram_size = (uint32_t)strtoul(argv[5], NULL, 16);
	if (argc >= 7)
		timebase = (uint32_t)strtoul(argv[6], NULL, 10);

	initrd_start = (uint32_t)strtoul(argv[1], NULL, 16);
	initrd_end   = (uint32_t)strtoul(argv[2], NULL, 16);
	cmdline      = argv[3];
	outpath      = argv[4];

	memset(buf, 0, sizeof(buf));
	memset(sbuf, 0, sizeof(sbuf));
	pos  = hdr_size + 16;
	spos = 0;

	/* root node */
	begin_node("");
	prop_u32("#address-cells", 1);
	prop_u32("#size-cells", 1);
	prop_str("compatible", "riscv-chimera");
	prop_str("model", "chimera,rv32-nommu");

	/* chosen */
	begin_node("chosen");
	prop_str("bootargs", cmdline);
	prop_u32("linux,initrd-start", initrd_start);
	prop_u32("linux,initrd-end",   initrd_end);
	end_node();

	/* cpus */
	begin_node("cpus");
	prop_u32("#address-cells", 1);
	prop_u32("#size-cells", 0);
	prop_u32("timebase-frequency", timebase);

	begin_node("cpu@0");
	prop_str("compatible", "riscv");
	prop_str("device_type", "cpu");
	prop_u32("reg", 0);
	prop_str("riscv,isa", "rv32ima");
	prop_str("mmu-type", "riscv,none");

	begin_node("interrupt-controller");
	prop_u32("#interrupt-cells", 1);
	prop_empty("interrupt-controller");
	prop_str("compatible", "riscv,cpu-intc");
	prop_u32("phandle", 1);
	end_node();

	end_node(); /* cpu@0 */
	end_node(); /* cpus */

	/* memory */
	begin_node("memory@80000000");
	prop_str("device_type", "memory");
	prop_reg32("reg", 0x80000000, ram_size);
	end_node();

	/* CLINT at 0x02000000 */
	memset(clint_reg, 0, sizeof(clint_reg));
	clint_reg[3]  = 0x02; clint_reg[4]  = 0x00; clint_reg[5]  = 0x00; clint_reg[6]  = 0x00; clint_reg[7]  = 0x00;
	clint_reg[11] = 0x00; clint_reg[12] = 0x01; clint_reg[13] = 0x00; clint_reg[14] = 0x00; clint_reg[15] = 0x00;

	/* encode CLINT reg as two cells: base 0x02000000 size 0x00010000 */
	{
		uint8_t r[8];
		r[0] = 0x02; r[1] = 0x00; r[2] = 0x00; r[3] = 0x00;
		r[4] = 0x00; r[5] = 0x01; r[6] = 0x00; r[7] = 0x00;
		begin_node("clint@2000000");
		prop_str("compatible", "riscv,clint0");
		prop(    "reg", r, 8);
		/* interrupts-extended: phandle 1, irq 3 (mswi), phandle 1, irq 7 (mtimer) */
		clint_intr[0]  = 0x00; clint_intr[1]  = 0x00;
		clint_intr[2]  = 0x00; clint_intr[3]  = 0x01;
		clint_intr[4]  = 0x00; clint_intr[5]  = 0x00;
		clint_intr[6]  = 0x00; clint_intr[7]  = 0x03;
		clint_intr[8]  = 0x00; clint_intr[9]  = 0x00;
		clint_intr[10] = 0x00; clint_intr[11] = 0x01;
		clint_intr[12] = 0x00; clint_intr[13] = 0x00;
		clint_intr[14] = 0x00; clint_intr[15] = 0x07;
		prop("interrupts-extended", clint_intr, 16);
		end_node();
	}

	/* NS16550 UART at 0x10000000 */
	begin_node("serial@10000000");
	prop_str("compatible", "ns16550a");
	prop_reg32("reg", 0x10000000, 0x100);
	prop_u32("clock-frequency", 3686400);
	prop_u32("reg-shift", 0);
	prop_u32("reg-io-width", 1);
	/*
	 * No interrupt line. Chimera implements no PLIC, and a device cannot
	 * be wired straight to the hart-local external line: riscv-intc maps
	 * its hwirqs as per-CPU devids, so request_irq() from the 8250 driver
	 * fails and the port is left unusable. With no interrupts-extended
	 * property the 8250 driver runs the port in timer-polled mode, which
	 * is what the CLINT-only hardware model in readme.md describes.
	 * Add a PLIC here when the NIC controller stage needs real device
	 * interrupts.
	 */
	(void)uart_intr;
	end_node();

	end_node(); /* root */

	w32(FDT_END);

	struct_off  = hdr_size + 16;
	struct_size = pos - struct_off;
	strings_off = pos;
	memcpy(buf + pos, sbuf, spos);
	pos += spos;
	total_size = pos;

	/* write FDT header */
	buf[0]  = (FDT_MAGIC >> 24) & 0xff;
	buf[1]  = (FDT_MAGIC >> 16) & 0xff;
	buf[2]  = (FDT_MAGIC >>  8) & 0xff;
	buf[3]  = (FDT_MAGIC >>  0) & 0xff;

	buf[4]  = (total_size  >> 24) & 0xff;
	buf[5]  = (total_size  >> 16) & 0xff;
	buf[6]  = (total_size  >>  8) & 0xff;
	buf[7]  = (total_size  >>  0) & 0xff;

	buf[8]  = (struct_off  >> 24) & 0xff;
	buf[9]  = (struct_off  >> 16) & 0xff;
	buf[10] = (struct_off  >>  8) & 0xff;
	buf[11] = (struct_off  >>  0) & 0xff;

	buf[12] = (strings_off >> 24) & 0xff;
	buf[13] = (strings_off >> 16) & 0xff;
	buf[14] = (strings_off >>  8) & 0xff;
	buf[15] = (strings_off >>  0) & 0xff;

	/* mem_rsvmap_offset: 16 zero bytes immediately after the header */
	buf[16] = (rsv_off >> 24) & 0xff;
	buf[17] = (rsv_off >> 16) & 0xff;
	buf[18] = (rsv_off >>  8) & 0xff;
	buf[19] = (rsv_off >>  0) & 0xff;

	/* version = 17 */
	buf[20] = 0; buf[21] = 0; buf[22] = 0; buf[23] = 17;
	/* last_comp_version = 16 */
	buf[24] = 0; buf[25] = 0; buf[26] = 0; buf[27] = 16;
	/* boot_cpuid_phys = 0 */
	buf[28] = 0; buf[29] = 0; buf[30] = 0; buf[31] = 0;
	/* size_dt_strings */
	buf[32] = (spos >> 24) & 0xff;
	buf[33] = (spos >> 16) & 0xff;
	buf[34] = (spos >>  8) & 0xff;
	buf[35] = (spos >>  0) & 0xff;
	/* size_dt_struct */
	buf[36] = (struct_size >> 24) & 0xff;
	buf[37] = (struct_size >> 16) & 0xff;
	buf[38] = (struct_size >>  8) & 0xff;
	buf[39] = (struct_size >>  0) & 0xff;

	f = fopen(outpath, "wb");
	if (!f) {
		perror("fopen");
		return 1;
	}
	fwrite(buf, 1, total_size, f);
	fclose(f);
	printf("wrote %u bytes to %s\n", total_size, outpath);
	return 0;
}
