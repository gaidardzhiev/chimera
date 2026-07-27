/*
 * Copyright (C) 2026 Ivan Gaydardzhiev
 * Licensed under the GPL-3.0-only
 */

#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <fcntl.h>
#include <termios.h>
#include <time.h>

#ifdef CHIMERA_CPU
#define DEV
#define GLOBAL
#else
#include <cuda_runtime.h>
#define DEV __device__
#define GLOBAL __global__
#endif

#ifndef RAM_SIZE
#define RAM_SIZE (32u*1024u*1024u)
#endif
#ifndef RO_SIZE
#define RO_SIZE 0u
#endif

#define RAM_BASE 0x80000000u
#define SLICE_SIZE (RAM_SIZE-RO_SIZE)
#define ENTRY_POINT RAM_BASE
#define INITRD_LOAD (RAM_BASE+0x00300000u)
#define DTB_LOAD (RAM_BASE+0x00400000u)

#define UART_BASE 0x10000000u
#define UART_SIZE 0x100u
#define UART_RBR 0x00
#define UART_THR 0x00
#define UART_IER 0x01
#define UART_IIR 0x02
#define UART_LCR 0x03
#define UART_MCR 0x04
#define UART_LSR 0x05
#define UART_MSR 0x06
#define UART_SCR 0x07
#define UART_LSR_DR 0x01
#define UART_LSR_THRE 0x20
#define UART_LSR_TEMT 0x40

#define CLINT_BASE 0x02000000u
#define CLINT_SIZE 0x10000u
#define CLINT_MTIMECMP 0x4000u
#define CLINT_MTIME 0xbff8u

#ifndef TIMER_QUANTUM
#define TIMER_QUANTUM 1u
#endif

#define IN_SIZE 4096
#define OUT_SIZE (64*1024)

#define MIE_MSI 0x008u
#define MIE_MTI 0x080u
#define MIE_MEI 0x800u

#define CAUSE_IALIGN 0
#define CAUSE_IFAULT 1
#define CAUSE_ILLEGAL 2
#define CAUSE_BREAK 3
#define CAUSE_LFAULT 5
#define CAUSE_SFAULT 7
#define CAUSE_ECALL_U 8
#define CAUSE_ECALL_M 11

#define ST_RUNNING 0
#define ST_EXIT 1
#define ST_RO_WRITE 2
#define ST_NO_HANDLER 3
#define ST_BUDGET 4
#define ST_DETACH 5

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
	uint32_t mtval;
	uint64_t mtime;
	uint64_t mtimecmp;
	uint32_t priv;
	uint32_t lr_addr;
	uint32_t lr_valid;
	uint32_t done;
	uint32_t status;
	uint32_t retval;
	uint32_t fault_cause;
	uint32_t fault_addr;
	uint32_t fault_pc;
	uint64_t steps;
} cpu_t;

typedef struct {
	cpu_t cpu;
	uint32_t in_head;
	uint32_t in_tail;
	uint32_t out_pos;
	uint32_t uart_ier;
	uint32_t uart_lcr;
	uint32_t uart_mcr;
	uint32_t uart_scr;
	uint32_t uart_dll;
	uint32_t uart_dlm;
	uint8_t in[IN_SIZE];
	uint8_t out[OUT_SIZE];
} ns_t;

static DEV uint8_t *ram_ptr(uint8_t *ro,uint8_t *mem,uint32_t off) {
	if (off<RO_SIZE)
		return ro+off;
	return mem+(off-RO_SIZE);
}

static DEV int ram_off(uint32_t addr,uint32_t len,uint32_t *off) {
	uint32_t p;
	if (addr<RAM_BASE)
		return 0;
	p=addr-RAM_BASE;
	if (p>RAM_SIZE-len)
		return 0;
	if (RO_SIZE&&p<RO_SIZE&&p+len>RO_SIZE)
		return 0;
	*off=p;
	return 1;
}

static DEV uint32_t mem_read(uint8_t *ro,uint8_t *mem,uint32_t addr,uint32_t len,int *ok) {
	uint32_t off,v;
	v=0;
	if (!ram_off(addr,len,&off)) {
		*ok=0;
		return 0;
	}
	memcpy(&v,ram_ptr(ro,mem,off),len);
	*ok=1;
	return v;
}

static DEV void mem_write(ns_t *ns,uint8_t *ro,uint8_t *mem,uint32_t addr,uint32_t len,uint32_t val,int *ok) {
	uint32_t off;
	if (!ram_off(addr,len,&off)) {
		*ok=0;
		return;
	}
	if (off<RO_SIZE) {
		ns->cpu.done=1;
		ns->cpu.status=ST_RO_WRITE;
		ns->cpu.fault_cause=CAUSE_SFAULT;
		ns->cpu.fault_addr=addr;
		ns->cpu.fault_pc=ns->cpu.pc;
		*ok=1;
		return;
	}
	memcpy(ram_ptr(ro,mem,off),&val,len);
	*ok=1;
}

static DEV uint32_t uart_irq(ns_t *ns) {
	if ((ns->uart_ier&0x01)&&ns->in_tail!=ns->in_head)
		return 0x04;
	if (ns->uart_ier&0x02)
		return 0x02;
	return 0x01;
}

static DEV uint32_t mmio_read(ns_t *ns,uint32_t addr) {
	uint32_t off;
	if (addr>=UART_BASE&&addr<UART_BASE+UART_SIZE) {
		off=addr-UART_BASE;
		if ((ns->uart_lcr&0x80)&&off<2)
			return off?ns->uart_dlm:ns->uart_dll;
		switch (off) {
		case UART_RBR:
			if (ns->in_tail!=ns->in_head)
				return ns->in[(ns->in_tail++)&(IN_SIZE-1)];
			return 0;
		case UART_IER:
			return ns->uart_ier;
		case UART_IIR:
			return 0xc0|uart_irq(ns);
		case UART_LCR:
			return ns->uart_lcr;
		case UART_MCR:
			return ns->uart_mcr;
		case UART_LSR:
			return UART_LSR_TEMT|UART_LSR_THRE|
				(ns->in_tail!=ns->in_head?UART_LSR_DR:0);
		case UART_MSR:
			return 0xb0;
		case UART_SCR:
			return ns->uart_scr;
		}
		return 0;
	}
	if (addr>=CLINT_BASE&&addr<CLINT_BASE+CLINT_SIZE) {
		off=addr-CLINT_BASE;
		switch (off) {
		case CLINT_MTIME:
			return (uint32_t)ns->cpu.mtime;
		case CLINT_MTIME+4:
			return (uint32_t)(ns->cpu.mtime>>32);
		case CLINT_MTIMECMP:
			return (uint32_t)ns->cpu.mtimecmp;
		case CLINT_MTIMECMP+4:
			return (uint32_t)(ns->cpu.mtimecmp>>32);
		}
		return 0;
	}
	return 0;
}

static DEV void mmio_write(ns_t *ns,uint32_t addr,uint32_t val) {
	uint32_t off;
	if (addr>=UART_BASE&&addr<UART_BASE+UART_SIZE) {
		off=addr-UART_BASE;
		if ((ns->uart_lcr&0x80)&&off<2) {
			if (off)
				ns->uart_dlm=val&0xff;
			else
				ns->uart_dll=val&0xff;
			return;
		}
		switch (off) {
		case UART_THR:
			if (ns->out_pos<OUT_SIZE)
				ns->out[ns->out_pos++]=(uint8_t)val;
			break;
		case UART_IER:
			ns->uart_ier=val&0x0f;
			break;
		case UART_LCR:
			ns->uart_lcr=val&0xff;
			break;
		case UART_MCR:
			ns->uart_mcr=val&0xff;
			break;
		case UART_SCR:
			ns->uart_scr=val&0xff;
			break;
		}
		return;
	}
	if (addr>=CLINT_BASE&&addr<CLINT_BASE+CLINT_SIZE) {
		off=addr-CLINT_BASE;
		switch (off) {
		case CLINT_MTIMECMP:
			ns->cpu.mtimecmp=(ns->cpu.mtimecmp&0xffffffff00000000ULL)|val;
			break;
		case CLINT_MTIMECMP+4:
			ns->cpu.mtimecmp=(ns->cpu.mtimecmp&0x00000000ffffffffULL)|
				((uint64_t)val<<32);
			break;
		}
		return;
	}
}

static DEV int is_mmio(uint32_t addr) {
	return (addr>=UART_BASE&&addr<UART_BASE+UART_SIZE)||
		(addr>=CLINT_BASE&&addr<CLINT_BASE+CLINT_SIZE);
}

static DEV void device_tick(ns_t *ns) {
	ns->cpu.mtime+=TIMER_QUANTUM;
	if (ns->cpu.mtime>=ns->cpu.mtimecmp)
		ns->cpu.mip|=MIE_MTI;
	else
		ns->cpu.mip&=~MIE_MTI;
	if (uart_irq(ns)!=0x01)
		ns->cpu.mip|=MIE_MEI;
	else
		ns->cpu.mip&=~MIE_MEI;
}

static DEV void trap(ns_t *ns,uint32_t cause,uint32_t tval,uint32_t epc) {
	uint32_t base;
	if (!ns->cpu.mtvec) {
		ns->cpu.done=1;
		ns->cpu.status=ST_NO_HANDLER;
		ns->cpu.fault_cause=cause;
		ns->cpu.fault_addr=tval;
		ns->cpu.fault_pc=epc;
		return;
	}
	ns->cpu.mepc=epc;
	ns->cpu.mcause=cause;
	ns->cpu.mtval=tval;
	ns->cpu.mstatus=(ns->cpu.mstatus&~0x1888u)|((ns->cpu.mstatus&0x8u)<<4)|
		(ns->cpu.priv<<11);
	ns->cpu.priv=3;
	base=ns->cpu.mtvec&~0x3u;
	if ((ns->cpu.mtvec&0x3)==1&&(cause&0x80000000u))
		ns->cpu.pc=base+4*(cause&0x7fffffffu);
	else
		ns->cpu.pc=base;
}

static DEV void interrupt_check(ns_t *ns) {
	uint32_t pending;
	if (ns->cpu.priv==3&&!(ns->cpu.mstatus&0x8))
		return;
	pending=ns->cpu.mie&ns->cpu.mip;
	if (!pending)
		return;
	if (pending&MIE_MEI)
		trap(ns,0x8000000bu,0,ns->cpu.pc);
	else if (pending&MIE_MSI)
		trap(ns,0x80000003u,0,ns->cpu.pc);
	else
		trap(ns,0x80000007u,0,ns->cpu.pc);
}

static DEV void csr_write(ns_t *ns,uint32_t csr,uint32_t val) {
	switch (csr) {
	case 0x300: ns->cpu.mstatus=val; break;
	case 0x304: ns->cpu.mie=val; break;
	case 0x305: ns->cpu.mtvec=val; break;
	case 0x340: ns->cpu.mscratch=val; break;
	case 0x341: ns->cpu.mepc=val; break;
	case 0x342: ns->cpu.mcause=val; break;
	case 0x343: ns->cpu.mtval=val; break;
	case 0x344: ns->cpu.mip=(ns->cpu.mip&(MIE_MTI|MIE_MEI))|(val&~(MIE_MTI|MIE_MEI)); break;
	}
}

static DEV uint32_t csr_read(ns_t *ns,uint32_t csr) {
	switch (csr) {
	case 0x300: return ns->cpu.mstatus;
	case 0x301: return (1u<<30)|(1u<<0)|(1u<<8)|(1u<<12);
	case 0x304: return ns->cpu.mie;
	case 0x305: return ns->cpu.mtvec;
	case 0x340: return ns->cpu.mscratch;
	case 0x341: return ns->cpu.mepc;
	case 0x342: return ns->cpu.mcause;
	case 0x343: return ns->cpu.mtval;
	case 0x344: return ns->cpu.mip;
	case 0xb00: case 0xc00: case 0xc01: return (uint32_t)ns->cpu.mtime;
	case 0xb80: case 0xc80: case 0xc81: return (uint32_t)(ns->cpu.mtime>>32);
	}
	return 0;
}

static DEV uint32_t itype(uint32_t imm,uint32_t rs1,uint32_t f3,uint32_t rd,uint32_t op) {
	return ((imm&0xfff)<<20)|(rs1<<15)|(f3<<12)|(rd<<7)|op;
}

static DEV uint32_t rtype(uint32_t f7,uint32_t rs2,uint32_t rs1,uint32_t f3,uint32_t rd,uint32_t op) {
	return (f7<<25)|(rs2<<20)|(rs1<<15)|(f3<<12)|(rd<<7)|op;
}

static DEV uint32_t stype(uint32_t imm,uint32_t rs2,uint32_t rs1,uint32_t f3,uint32_t op) {
	return (((imm>>5)&0x7f)<<25)|(rs2<<20)|(rs1<<15)|(f3<<12)|((imm&0x1f)<<7)|op;
}

static DEV uint32_t btype(uint32_t imm,uint32_t rs2,uint32_t rs1,uint32_t f3) {
	return (((imm>>12)&1)<<31)|(((imm>>5)&0x3f)<<25)|(rs2<<20)|(rs1<<15)|
		(f3<<12)|(((imm>>1)&0xf)<<8)|(((imm>>11)&1)<<7)|0x63;
}

static DEV uint32_t jtype(uint32_t imm,uint32_t rd) {
	return (((imm>>20)&1)<<31)|(((imm>>1)&0x3ff)<<21)|(((imm>>11)&1)<<20)|
		(((imm>>12)&0xff)<<12)|(rd<<7)|0x6f;
}

static DEV uint32_t decompress(uint32_t c) {
	uint32_t q,f3,rd,rs2,rp,sp,u,sh;
	int32_t s;
	q=c&0x3;
	f3=(c>>13)&0x7;
	rd=(c>>7)&0x1f;
	rs2=(c>>2)&0x1f;
	rp=8+((c>>2)&0x7);
	sp=8+((c>>7)&0x7);
	if (q==0) {
		switch (f3) {
		case 0x0:
			u=(((c>>6)&1)<<2)|(((c>>5)&1)<<3)|(((c>>11)&3)<<4)|(((c>>7)&0xf)<<6);
			if (!u)
				return 0;
			return itype(u,2,0x0,rp,0x13);
		case 0x2:
			u=(((c>>10)&0x7)<<3)|(((c>>6)&1)<<2)|(((c>>5)&1)<<6);
			return itype(u,sp,0x2,rp,0x03);
		case 0x6:
			u=(((c>>10)&0x7)<<3)|(((c>>6)&1)<<2)|(((c>>5)&1)<<6);
			return stype(u,rp,sp,0x2,0x23);
		}
		return 0;
	}
	if (q==1) {
		switch (f3) {
		case 0x0:
			s=(int32_t)((((c>>12)&1)<<5)|rs2);
			if (s&0x20)
				s|=~0x3f;
			return itype((uint32_t)s,rd,0x0,rd,0x13);
		case 0x1:
		case 0x5:
			s=(int32_t)((((c>>12)&1)<<11)|(((c>>11)&1)<<4)|(((c>>9)&3)<<8)|
				(((c>>8)&1)<<10)|(((c>>7)&1)<<6)|(((c>>6)&1)<<7)|
				(((c>>3)&7)<<1)|(((c>>2)&1)<<5));
			if (s&0x800)
				s|=~0xfff;
			return jtype((uint32_t)s,f3==0x1?1:0);
		case 0x2:
			s=(int32_t)((((c>>12)&1)<<5)|rs2);
			if (s&0x20)
				s|=~0x3f;
			return itype((uint32_t)s,0,0x0,rd,0x13);
		case 0x3:
			if (rd==2) {
				s=(int32_t)((((c>>12)&1)<<9)|(((c>>6)&1)<<4)|(((c>>5)&1)<<6)|
					(((c>>3)&3)<<7)|(((c>>2)&1)<<5));
				if (s&0x200)
					s|=~0x3ff;
				if (!s)
					return 0;
				return itype((uint32_t)s,2,0x0,2,0x13);
			}
			s=(int32_t)((((c>>12)&1)<<17)|(rs2<<12));
			if (s&0x20000)
				s|=~0x3ffff;
			if (!s||!rd)
				return 0;
			return (((uint32_t)s>>12)&0xfffff)<<12|(rd<<7)|0x37;
		case 0x4:
			sh=(((c>>12)&1)<<5)|rs2;
			switch ((c>>10)&0x3) {
			case 0x0:
				return itype(sh,sp,0x5,sp,0x13);
			case 0x1:
				return itype(0x400|sh,sp,0x5,sp,0x13);
			case 0x2:
				s=(int32_t)sh;
				if (s&0x20)
					s|=~0x3f;
				return itype((uint32_t)s,sp,0x7,sp,0x13);
			}
			if ((c>>12)&1)
				return 0;
			switch ((c>>5)&0x3) {
			case 0x0: return rtype(0x20,rp,sp,0x0,sp,0x33);
			case 0x1: return rtype(0x00,rp,sp,0x4,sp,0x33);
			case 0x2: return rtype(0x00,rp,sp,0x6,sp,0x33);
			case 0x3: return rtype(0x00,rp,sp,0x7,sp,0x33);
			}
			return 0;
		case 0x6:
		case 0x7:
			s=(int32_t)((((c>>12)&1)<<8)|(((c>>10)&3)<<3)|(((c>>5)&3)<<6)|
				(((c>>3)&3)<<1)|(((c>>2)&1)<<5));
			if (s&0x100)
				s|=~0x1ff;
			return btype((uint32_t)s,0,sp,f3==0x6?0x0:0x1);
		}
		return 0;
	}
	if (q==2) {
		switch (f3) {
		case 0x0:
				sh=(((c>>12)&1)<<5)|rs2;
			return itype(sh,rd,0x1,rd,0x13);
		case 0x2:
			u=(((c>>12)&1)<<5)|(((c>>4)&0x7)<<2)|(((c>>2)&0x3)<<6);
			if (!rd)
				return 0;
			return itype(u,2,0x2,rd,0x03);
		case 0x4:
			if (!((c>>12)&1)) {
				if (!rs2)
					return rd?itype(0,rd,0x0,0,0x67):0;
				return rtype(0x00,rs2,0,0x0,rd,0x33);
			}
			if (!rs2)
				return rd?itype(0,rd,0x0,1,0x67):0x00100073u;
			return rtype(0x00,rs2,rd,0x0,rd,0x33);
		case 0x6:
			u=(((c>>9)&0xf)<<2)|(((c>>7)&0x3)<<6);
			return stype(u,rs2,2,0x2,0x23);
		}
		return 0;
	}
	return 0;
}

static DEV void fetch_decode_execute(ns_t *ns,uint8_t *ro,uint8_t *mem) {
	uint32_t ir,op,rd,rs1,rs2,funct3,funct7,funct5;
	uint32_t imm,addr,val,old,csr,epc,lo,hi,ilen;
	int32_t simm;
	int ok;
	epc=ns->cpu.pc;
	if (epc&0x1) {
		trap(ns,CAUSE_IALIGN,epc,epc);
		return;
	}
	lo=mem_read(ro,mem,epc,2,&ok);
	if (!ok) {
		trap(ns,CAUSE_IFAULT,epc,epc);
		return;
	}
	if ((lo&0x3)!=0x3) {
		ilen=2;
		ir=decompress(lo);
		if (!ir) {
			trap(ns,CAUSE_ILLEGAL,lo,epc);
			return;
		}
	} else {
		ilen=4;
		hi=mem_read(ro,mem,epc+2,2,&ok);
		if (!ok) {
			trap(ns,CAUSE_IFAULT,epc,epc);
			return;
		}
		ir=lo|(hi<<16);
	}
	op=ir&0x7f;
	rd=(ir>>7)&0x1f;
	funct3=(ir>>12)&0x07;
	rs1=(ir>>15)&0x1f;
	rs2=(ir>>20)&0x1f;
	funct7=(ir>>25)&0x7f;
	ns->cpu.x[0]=0;
	ns->cpu.pc=epc+ilen;
	switch (op) {
	case 0x37:
		if (rd)
			ns->cpu.x[rd]=ir&0xfffff000;
		break;
	case 0x17:
		if (rd)
			ns->cpu.x[rd]=epc+(ir&0xfffff000);
		break;
	case 0x6f:
		imm=((ir>>31)&1)<<20|((ir>>12)&0xff)<<12|
			((ir>>20)&1)<<11|((ir>>21)&0x3ff)<<1;
		if (imm&(1<<20))
			imm|=0xffe00000;
		if (rd)
			ns->cpu.x[rd]=epc+ilen;
		ns->cpu.pc=epc+imm;
		break;
	case 0x67:
		simm=(int32_t)ir>>20;
		val=epc+ilen;
		ns->cpu.pc=(ns->cpu.x[rs1]+simm)&~1u;
		if (rd)
			ns->cpu.x[rd]=val;
		break;
	case 0x63:
		imm=((ir>>31)&1)<<12|((ir>>7)&1)<<11|
			((ir>>25)&0x3f)<<5|((ir>>8)&0xf)<<1;
		if (imm&(1<<12))
			imm|=0xffffe000;
		switch (funct3) {
		case 0x0:
			if (ns->cpu.x[rs1]==ns->cpu.x[rs2])
				ns->cpu.pc=epc+imm;
			break;
		case 0x1:
			if (ns->cpu.x[rs1]!=ns->cpu.x[rs2])
				ns->cpu.pc=epc+imm;
			break;
		case 0x4:
			if ((int32_t)ns->cpu.x[rs1]<(int32_t)ns->cpu.x[rs2])
				ns->cpu.pc=epc+imm;
			break;
		case 0x5:
			if ((int32_t)ns->cpu.x[rs1]>=(int32_t)ns->cpu.x[rs2])
				ns->cpu.pc=epc+imm;
			break;
		case 0x6:
			if (ns->cpu.x[rs1]<ns->cpu.x[rs2])
				ns->cpu.pc=epc+imm;
			break;
		case 0x7:
			if (ns->cpu.x[rs1]>=ns->cpu.x[rs2])
				ns->cpu.pc=epc+imm;
			break;
		default:
			trap(ns,CAUSE_ILLEGAL,ir,epc);
		}
		break;
	case 0x03:
		simm=(int32_t)ir>>20;
		addr=ns->cpu.x[rs1]+simm;
		val=0;
		ok=1;
		switch (funct3) {
		case 0x0:
		case 0x4:
			val=is_mmio(addr)?mmio_read(ns,addr):mem_read(ro,mem,addr,1,&ok);
			break;
		case 0x1:
		case 0x5:
			val=is_mmio(addr)?mmio_read(ns,addr):mem_read(ro,mem,addr,2,&ok);
			break;
		case 0x2:
			val=is_mmio(addr)?mmio_read(ns,addr):mem_read(ro,mem,addr,4,&ok);
			break;
		default:
			trap(ns,CAUSE_ILLEGAL,ir,epc);
			return;
		}
		if (!ok) {
			trap(ns,CAUSE_LFAULT,addr,epc);
			return;
		}
		if (rd) {
			if (funct3==0x0)
				ns->cpu.x[rd]=(uint32_t)(int32_t)(int8_t)val;
			else if (funct3==0x1)
				ns->cpu.x[rd]=(uint32_t)(int32_t)(int16_t)val;
			else if (funct3==0x4)
				ns->cpu.x[rd]=val&0xff;
			else if (funct3==0x5)
				ns->cpu.x[rd]=val&0xffff;
			else
				ns->cpu.x[rd]=val;
		}
		break;
	case 0x23:
		imm=((ir>>25)&0x7f)<<5|((ir>>7)&0x1f);
		if (imm&(1<<11))
			imm|=0xfffff000;
		addr=ns->cpu.x[rs1]+imm;
		val=ns->cpu.x[rs2];
		ok=1;
		switch (funct3) {
		case 0x0:
			if (is_mmio(addr))
				mmio_write(ns,addr,val);
			else
				mem_write(ns,ro,mem,addr,1,val,&ok);
			break;
		case 0x1:
			if (is_mmio(addr))
				mmio_write(ns,addr,val);
			else
				mem_write(ns,ro,mem,addr,2,val,&ok);
			break;
		case 0x2:
			if (is_mmio(addr))
				mmio_write(ns,addr,val);
			else
				mem_write(ns,ro,mem,addr,4,val,&ok);
			break;
		default:
			trap(ns,CAUSE_ILLEGAL,ir,epc);
			return;
		}
		if (!ok)
			trap(ns,CAUSE_SFAULT,addr,epc);
		break;
	case 0x0f:
		break;
	case 0x13:
		simm=(int32_t)ir>>20;
		switch (funct3) {
		case 0x0:
			if (rd) ns->cpu.x[rd]=ns->cpu.x[rs1]+simm;
			break;
		case 0x1:
			if (rd) ns->cpu.x[rd]=ns->cpu.x[rs1]<<(rs2&0x1f);
			break;
		case 0x2:
			if (rd) ns->cpu.x[rd]=(int32_t)ns->cpu.x[rs1]<simm?1:0;
			break;
		case 0x3:
			if (rd) ns->cpu.x[rd]=ns->cpu.x[rs1]<(uint32_t)simm?1:0;
			break;
		case 0x4:
			if (rd) ns->cpu.x[rd]=ns->cpu.x[rs1]^simm;
			break;
		case 0x5:
			if (funct7==0x20) {
				if (rd) ns->cpu.x[rd]=(uint32_t)((int32_t)ns->cpu.x[rs1]>>(rs2&0x1f));
			} else {
				if (rd) ns->cpu.x[rd]=ns->cpu.x[rs1]>>(rs2&0x1f);
			}
			break;
		case 0x6:
			if (rd) ns->cpu.x[rd]=ns->cpu.x[rs1]|simm;
			break;
		case 0x7:
			if (rd) ns->cpu.x[rd]=ns->cpu.x[rs1]&simm;
			break;
		}
		break;
	case 0x33:
		switch (funct3) {
		case 0x0:
			if (funct7==0x20) {
				if (rd) ns->cpu.x[rd]=ns->cpu.x[rs1]-ns->cpu.x[rs2];
			} else if (funct7==0x01) {
				if (rd) ns->cpu.x[rd]=(uint32_t)((int32_t)ns->cpu.x[rs1]*(int32_t)ns->cpu.x[rs2]);
			} else {
				if (rd) ns->cpu.x[rd]=ns->cpu.x[rs1]+ns->cpu.x[rs2];
			}
			break;
		case 0x1:
			if (funct7==0x01) {
				int64_t a=(int64_t)(int32_t)ns->cpu.x[rs1]*(int64_t)(int32_t)ns->cpu.x[rs2];
				if (rd) ns->cpu.x[rd]=(uint32_t)((uint64_t)a>>32);
			} else {
				if (rd) ns->cpu.x[rd]=ns->cpu.x[rs1]<<(ns->cpu.x[rs2]&0x1f);
			}
			break;
		case 0x2:
			if (funct7==0x01) {
				int64_t a=(int64_t)(int32_t)ns->cpu.x[rs1]*(int64_t)(uint32_t)ns->cpu.x[rs2];
				if (rd) ns->cpu.x[rd]=(uint32_t)((uint64_t)a>>32);
			} else {
				if (rd) ns->cpu.x[rd]=(int32_t)ns->cpu.x[rs1]<(int32_t)ns->cpu.x[rs2]?1:0;
			}
			break;
		case 0x3:
			if (funct7==0x01) {
				uint64_t a=(uint64_t)ns->cpu.x[rs1]*(uint64_t)ns->cpu.x[rs2];
				if (rd) ns->cpu.x[rd]=(uint32_t)(a>>32);
			} else {
				if (rd) ns->cpu.x[rd]=ns->cpu.x[rs1]<ns->cpu.x[rs2]?1:0;
			}
			break;
		case 0x4:
			if (funct7==0x01) {
				if (ns->cpu.x[rs2]==0) {
					if (rd) ns->cpu.x[rd]=0xffffffffu;
				} else if (ns->cpu.x[rs1]==0x80000000u&&ns->cpu.x[rs2]==0xffffffffu) {
					if (rd) ns->cpu.x[rd]=0x80000000u;
				} else {
					if (rd) ns->cpu.x[rd]=(uint32_t)((int32_t)ns->cpu.x[rs1]/(int32_t)ns->cpu.x[rs2]);
				}
			} else {
				if (rd) ns->cpu.x[rd]=ns->cpu.x[rs1]^ns->cpu.x[rs2];
			}
			break;
		case 0x5:
			if (funct7==0x01) {
				if (ns->cpu.x[rs2]==0) {
					if (rd) ns->cpu.x[rd]=0xffffffffu;
				} else {
					if (rd) ns->cpu.x[rd]=ns->cpu.x[rs1]/ns->cpu.x[rs2];
				}
			} else if (funct7==0x20) {
				if (rd) ns->cpu.x[rd]=(uint32_t)((int32_t)ns->cpu.x[rs1]>>(ns->cpu.x[rs2]&0x1f));
			} else {
				if (rd) ns->cpu.x[rd]=ns->cpu.x[rs1]>>(ns->cpu.x[rs2]&0x1f);
			}
			break;
		case 0x6:
			if (funct7==0x01) {
				if (ns->cpu.x[rs2]==0) {
					if (rd) ns->cpu.x[rd]=ns->cpu.x[rs1];
				} else if (ns->cpu.x[rs1]==0x80000000u&&ns->cpu.x[rs2]==0xffffffffu) {
					if (rd) ns->cpu.x[rd]=0;
				} else {
					if (rd) ns->cpu.x[rd]=(uint32_t)((int32_t)ns->cpu.x[rs1]%(int32_t)ns->cpu.x[rs2]);
				}
			} else {
				if (rd) ns->cpu.x[rd]=ns->cpu.x[rs1]|ns->cpu.x[rs2];
			}
			break;
		case 0x7:
			if (funct7==0x01) {
				if (ns->cpu.x[rs2]==0) {
					if (rd) ns->cpu.x[rd]=ns->cpu.x[rs1];
				} else {
					if (rd) ns->cpu.x[rd]=ns->cpu.x[rs1]%ns->cpu.x[rs2];
				}
			} else {
				if (rd) ns->cpu.x[rd]=ns->cpu.x[rs1]&ns->cpu.x[rs2];
			}
			break;
		}
		break;
	case 0x2f:
		if (funct3!=0x2) {
			trap(ns,CAUSE_ILLEGAL,ir,epc);
			break;
		}
		funct5=funct7>>2;
		addr=ns->cpu.x[rs1];
		val=ns->cpu.x[rs2];
		ok=1;
		if (funct5==0x03) {
			if (ns->cpu.lr_valid&&ns->cpu.lr_addr==addr) {
				mem_write(ns,ro,mem,addr,4,val,&ok);
				if (!ok) {
					trap(ns,CAUSE_SFAULT,addr,epc);
					break;
				}
				if (rd) ns->cpu.x[rd]=0;
			} else {
				if (rd) ns->cpu.x[rd]=1;
			}
			ns->cpu.lr_valid=0;
			break;
		}
		old=mem_read(ro,mem,addr,4,&ok);
		if (!ok) {
			trap(ns,CAUSE_LFAULT,addr,epc);
			break;
		}
		switch (funct5) {
		case 0x02:
			ns->cpu.lr_addr=addr;
			ns->cpu.lr_valid=1;
			break;
		case 0x01: mem_write(ns,ro,mem,addr,4,val,&ok); break;
		case 0x00: mem_write(ns,ro,mem,addr,4,old+val,&ok); break;
		case 0x04: mem_write(ns,ro,mem,addr,4,old^val,&ok); break;
		case 0x0c: mem_write(ns,ro,mem,addr,4,old&val,&ok); break;
		case 0x08: mem_write(ns,ro,mem,addr,4,old|val,&ok); break;
		case 0x10: mem_write(ns,ro,mem,addr,4,(int32_t)old<(int32_t)val?old:val,&ok); break;
		case 0x14: mem_write(ns,ro,mem,addr,4,(int32_t)old>(int32_t)val?old:val,&ok); break;
		case 0x18: mem_write(ns,ro,mem,addr,4,old<val?old:val,&ok); break;
		case 0x1c: mem_write(ns,ro,mem,addr,4,old>val?old:val,&ok); break;
		default:
			trap(ns,CAUSE_ILLEGAL,ir,epc);
			return;
		}
		if (!ok) {
			trap(ns,CAUSE_SFAULT,addr,epc);
			break;
		}
		if (rd) ns->cpu.x[rd]=old;
		break;
	case 0x73:
		csr=ir>>20;
		if (funct3==0x0) {
			switch (csr) {
			case 0x000:
				if (!ns->cpu.mtvec) {
					ns->cpu.done=1;
					ns->cpu.status=ST_EXIT;
					ns->cpu.retval=ns->cpu.x[10];
				} else {
					trap(ns,ns->cpu.priv==3?CAUSE_ECALL_M:CAUSE_ECALL_U,0,epc);
				}
				break;
			case 0x001:
				trap(ns,CAUSE_BREAK,epc,epc);
				break;
			case 0x302:
				if (ns->cpu.priv!=3) {
					trap(ns,CAUSE_ILLEGAL,ir,epc);
					break;
				}
				ns->cpu.priv=(ns->cpu.mstatus>>11)&0x3;
				ns->cpu.mstatus=(ns->cpu.mstatus&~0x1888u)|
					((ns->cpu.mstatus>>4)&0x8u)|0x80u;
				ns->cpu.pc=ns->cpu.mepc;
				break;
			case 0x105:
				if (!(ns->cpu.mie&ns->cpu.mip)&&(ns->cpu.mie&MIE_MTI)&&ns->cpu.mtimecmp>ns->cpu.mtime)
					ns->cpu.mtime=ns->cpu.mtimecmp-1;
				break;
			default:
				if ((csr&0xfe0u)!=0x120u)
					trap(ns,CAUSE_ILLEGAL,ir,epc);
			}
			break;
		}
		if (funct3==0x4||ns->cpu.priv!=3) {
			trap(ns,CAUSE_ILLEGAL,ir,epc);
			break;
		}
		old=csr_read(ns,csr);
		val=(funct3&0x4)?rs1:ns->cpu.x[rs1];
		switch (funct3&0x3) {
		case 0x1:
			csr_write(ns,csr,val);
			break;
		case 0x2:
			if (rs1) csr_write(ns,csr,old|val);
			break;
		case 0x3:
			if (rs1) csr_write(ns,csr,old&~val);
			break;
		}
		if (rd) ns->cpu.x[rd]=old;
		break;
	default:
		trap(ns,CAUSE_ILLEGAL,ir,epc);
		break;
	}
}

static DEV void run_slice(ns_t *ns,uint8_t *ro,uint8_t *mem,uint64_t budget) {
	uint64_t i;
	for (i=0;i<budget&&!ns->cpu.done;i++) {
		device_tick(ns);
		interrupt_check(ns);
		fetch_decode_execute(ns,ro,mem);
		ns->cpu.steps++;
	}
}

#ifndef CHIMERA_CPU
GLOBAL void chimera_fill(uint8_t *slices,const uint8_t *tmpl,uint32_t n) {
	uint32_t i;
	uint8_t *d;
	if (blockIdx.x>=n)
		return;
	d=slices+(size_t)blockIdx.x*SLICE_SIZE;
	for (i=threadIdx.x;i<SLICE_SIZE;i+=blockDim.x)
		d[i]=tmpl[RO_SIZE+i];
}

GLOBAL void chimera_step(ns_t *namespaces,uint8_t *ro,uint8_t *slices,uint32_t n,uint64_t budget) {
	uint32_t tid=blockIdx.x*blockDim.x+threadIdx.x;
	if (tid>=n)
		return;
	run_slice(&namespaces[tid],ro,slices+(size_t)tid*SLICE_SIZE,budget);
}
#endif

static const char *status_name(uint32_t s) {
	switch (s) {
	case ST_RUNNING: return "running";
	case ST_EXIT: return "exit";
	case ST_RO_WRITE: return "faulted: write to shared read-only region";
	case ST_NO_HANDLER: return "faulted: trap with mtvec unset";
	case ST_BUDGET: return "stopped: step budget exhausted";
	case ST_DETACH: return "stopped: console detached";
	}
	return "unknown";
}

static struct termios saved_tio;
static int tio_saved;
static int in_tty;
static int in_eof;
static int in_quit;

static void console_restore(void) {
	if (tio_saved)
		tcsetattr(0,TCSANOW,&saved_tio);
	tio_saved=0;
}

static void console_raw(void) {
	struct termios t;
	int fl;
	fl=fcntl(0,F_GETFL,0);
	if (fl!=-1)
		fcntl(0,F_SETFL,fl|O_NONBLOCK);
	if (!isatty(0))
		return;
	in_tty=1;
	if (tcgetattr(0,&saved_tio))
		return;
	saved_tio.c_lflag|=ECHO;
	t=saved_tio;
	t.c_lflag&=~(ICANON|ECHO|ISIG);
	t.c_iflag&=~(IXON|ICRNL);
	t.c_cc[VMIN]=0;
	t.c_cc[VTIME]=0;
	if (tcsetattr(0,TCSANOW,&t))
		return;
	tio_saved=1;
	atexit(console_restore);
	fprintf(stderr,"chimera: console attached, ctrl-] to detach\n");
}

static void console_pump(ns_t *ns) {
	uint8_t buf[256];
	uint32_t space,i;
	ssize_t r;
	if (in_eof)
		return;
	space=IN_SIZE-(ns->in_head-ns->in_tail);
	if (space>sizeof(buf))
		space=sizeof(buf);
	if (!space)
		return;
	r=read(0,buf,space);
	if (!r) {
		if (!in_tty)
			in_eof=1;
		return;
	}
	if (r<0)
		return;
	for (i=0;i<(uint32_t)r;i++) {
		if (buf[i]==0x1d) {
			in_quit=1;
			return;
		}
		ns->in[(ns->in_head++)&(IN_SIZE-1)]=buf[i];
	}
}

static void die(const char *msg) {
	fprintf(stderr,"chimera: %s\n",msg);
	exit(1);
}

static void load_binary(uint8_t *base,uint32_t off,const char *path) {
	FILE *f;
	long sz;
	f=fopen(path,"rb");
	if (!f) {
		fprintf(stderr,"chimera: cannot open %s\n",path);
		exit(1);
	}
	fseek(f,0,SEEK_END);
	sz=ftell(f);
	rewind(f);
	if (sz<0||(uint64_t)off+(uint64_t)sz>(uint64_t)RAM_SIZE) {
		fprintf(stderr,"chimera: %s (%ld bytes) does not fit at 0x%08x in %u bytes of RAM\n",
			path,sz,RAM_BASE+off,RAM_SIZE);
		exit(1);
	}
	if (fread(base+off,1,(size_t)sz,f)!=(size_t)sz)
		die("short read");
	fclose(f);
	fprintf(stderr,"chimera: loaded %-16s %8ld bytes at 0x%08x\n",path,sz,RAM_BASE+off);
}

static void report(ns_t *ns,uint32_t i) {
	fprintf(stderr,"\nchimera: ns[%u] %s pc=0x%08x steps=%llu out=%u",
		i,status_name(ns->cpu.status),ns->cpu.pc,
		(unsigned long long)ns->cpu.steps,ns->out_pos);
	if (ns->cpu.status==ST_RO_WRITE||ns->cpu.status==ST_NO_HANDLER)
		fprintf(stderr," cause=%u addr=0x%08x fault_pc=0x%08x",
			ns->cpu.fault_cause,ns->cpu.fault_addr,ns->cpu.fault_pc);
	if (ns->cpu.status==ST_EXIT)
		fprintf(stderr," retval=%u",ns->cpu.retval);
	fprintf(stderr,"\n");
}

static double now(void) {
	struct timespec ts;
	clock_gettime(CLOCK_MONOTONIC,&ts);
	return (double)ts.tv_sec+(double)ts.tv_nsec*1e-9;
}

static void perf(ns_t *ns,uint32_t n,double dt) {
	uint64_t rs;
	uint32_t i;
	rs=0;
	for (i=0;i<n;i++)
		rs+=ns[i].cpu.steps;
	fprintf(stderr,"chimera: n=%u wall=%.3fs steps=%llu rate=%.2fM/s each=%.2fM/s\n",
		n,dt,(unsigned long long)rs,rs/dt/1e6,rs/dt/1e6/n);
}

int main(int argc,char **argv) {
	uint32_t n,i;
	uint8_t *tmpl;
	ns_t *h_ns;
	uint64_t max_steps,total,chunk;
	double t0,dt;
	char ms[24];
	int kernel_mode;
	const char *env;
	if (argc==3) {
		kernel_mode=0;
	} else if (argc==5) {
		kernel_mode=1;
	} else {
		fprintf(stderr,
			"usage: %s <binary.bin> <n>\n"
			"       %s <kernel.bin> <initrd.bin> <chimera.dtb> <n>\n"
			"env:   CHIMERA_MAX_STEPS (step cap for batch runs, 0 or unset is no cap)\n"
			"       CHIMERA_CHUNK     (steps per launch, default 20000000)\n"
			"stdin is fed to the uart of namespace 0; ctrl-] detaches\n",
			argv[0],argv[0]);
		return 1;
	}
	n=(uint32_t)strtoul(argv[argc-1],NULL,10);
	if (!n)
		die("n must be > 0");
	env=getenv("CHIMERA_MAX_STEPS");
	max_steps=env?strtoull(env,NULL,10):0ULL;
	env=getenv("CHIMERA_CHUNK");
	chunk=env?strtoull(env,NULL,10):20000000ULL;
	if (!chunk)
		die("CHIMERA_CHUNK must be > 0");
	tmpl=(uint8_t *)calloc(1,RAM_SIZE);
	if (!tmpl)
		die("calloc ram template failed");
	load_binary(tmpl,0,argv[1]);
	if (kernel_mode) {
		load_binary(tmpl,INITRD_LOAD-RAM_BASE,argv[2]);
		load_binary(tmpl,DTB_LOAD-RAM_BASE,argv[3]);
	}
	h_ns=(ns_t *)calloc(n,sizeof(ns_t));
	if (!h_ns)
		die("calloc ns failed");
	for (i=0;i<n;i++) {
		h_ns[i].cpu.pc=ENTRY_POINT;
		h_ns[i].cpu.priv=3;
		h_ns[i].cpu.mtimecmp=~0ULL;
		h_ns[i].uart_lcr=0x03;
		if (kernel_mode) {
			h_ns[i].cpu.x[10]=0;
			h_ns[i].cpu.x[11]=DTB_LOAD;
		}
	}
	if (max_steps)
		snprintf(ms,sizeof(ms),"%llu",(unsigned long long)max_steps);
	else
		snprintf(ms,sizeof(ms),"none");
	fprintf(stderr,"chimera: ram=%uM ro=%uM slice=%uM n=%u max_steps=%s\n",
		RAM_SIZE>>20,RO_SIZE>>20,SLICE_SIZE>>20,n,ms);
#ifdef CHIMERA_CPU
	{
		uint32_t seen=0;
		if (n!=1)
			die("cpu build runs a single namespace");
		total=0;
		console_raw();
		t0=now();
		while (!h_ns[0].cpu.done&&(!max_steps||total<max_steps)&&!in_quit) {
			console_pump(&h_ns[0]);
			run_slice(&h_ns[0],tmpl,tmpl+RO_SIZE,chunk);
			total+=chunk;
			while (seen<h_ns[0].out_pos)
				fputc(h_ns[0].out[seen++],stderr);
			fflush(stderr);
		}
		dt=now()-t0;
		console_restore();
		if (!h_ns[0].cpu.done)
			h_ns[0].cpu.status=in_quit?ST_DETACH:ST_BUDGET;
		perf(h_ns,n,dt);
		report(&h_ns[0],0);
		if (h_ns[0].out_pos)
			fwrite(h_ns[0].out,1,h_ns[0].out_pos,stdout);
	}
#else
	{
		ns_t *d_ns;
		uint8_t *d_ro,*d_slices;
		uint32_t blocks,threads,seen,live;
		cudaError_t e;
		seen=0;
		e=cudaMalloc(&d_slices,(size_t)n*SLICE_SIZE);
		if (e!=cudaSuccess) {
			fprintf(stderr,"chimera: cudaMalloc %llu bytes for %u slices: %s\n",
				(unsigned long long)((size_t)n*SLICE_SIZE),n,cudaGetErrorString(e));
			return 1;
		}
		if (cudaMalloc(&d_ro,RAM_SIZE)!=cudaSuccess)
			die("cudaMalloc template failed");
		if (cudaMalloc(&d_ns,(size_t)n*sizeof(ns_t))!=cudaSuccess)
			die("cudaMalloc ns failed");
		cudaMemcpy(d_ro,tmpl,RAM_SIZE,cudaMemcpyHostToDevice);
		cudaMemcpy(d_ns,h_ns,(size_t)n*sizeof(ns_t),cudaMemcpyHostToDevice);
		chimera_fill<<<n,256>>>(d_slices,d_ro,n);
		if (cudaDeviceSynchronize()!=cudaSuccess)
			die("slice fill failed");
		threads=256;
		blocks=(n+threads-1)/threads;
		total=0;
		live=1;
		console_raw();
		t0=now();
		while (live&&(!max_steps||total<max_steps)&&!in_quit) {
			console_pump(&h_ns[0]);
			cudaMemcpy(d_ns,h_ns,sizeof(ns_t),cudaMemcpyHostToDevice);
			chimera_step<<<blocks,threads>>>(d_ns,d_ro,d_slices,n,chunk);
			e=cudaDeviceSynchronize();
			if (e!=cudaSuccess) {
				fprintf(stderr,"chimera: launch failed: %s\n",cudaGetErrorString(e));
				break;
			}
			cudaMemcpy(h_ns,d_ns,(size_t)n*sizeof(ns_t),cudaMemcpyDeviceToHost);
			total+=chunk;
			while (seen<h_ns[0].out_pos)
				fputc(h_ns[0].out[seen++],stderr);
			fflush(stderr);
			live=0;
			for (i=0;i<n;i++)
				if (!h_ns[i].cpu.done)
					live=1;
		}
		dt=now()-t0;
		console_restore();
		for (i=0;i<n;i++)
			if (!h_ns[i].cpu.done)
				h_ns[i].cpu.status=in_quit?ST_DETACH:ST_BUDGET;
		perf(h_ns,n,dt);
		report(&h_ns[0],0);
		for (i=0;i<n;i++)
			if (h_ns[i].out_pos)
				fwrite(h_ns[i].out,1,h_ns[i].out_pos,stdout);
		cudaFree(d_ns);
		cudaFree(d_ro);
		cudaFree(d_slices);
	}
#endif
	free(h_ns);
	free(tmpl);
	return 0;
}
