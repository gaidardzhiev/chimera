CROSS=riscv32-unknown-elf-
AS=$(CROSS)as
LD=$(CROSS)ld
OBJCOPY=$(CROSS)objcopy
ASFLAGS=-march=rv32ima_zicsr_zifencei -mabi=ilp32
LDFLAGS=-T link.ld -m elf32lriscv
QEMU=qemu-system-riscv32
QFLAGS=-machine virt -nographic -bios none -kernel

all: uart.elf clint.elf

uart.elf: uart.o
	$(LD) $(LDFLAGS) -o $@ $<

uart.o: uart.s
	$(AS) $(ASFLAGS) -o $@ $<

clint.elf: clint.o
	$(LD) $(LDFLAGS) -o $@ $<

clint.o: clint.s
	$(AS) $(ASFLAGS) -o $@ $<

qemu-uart: uart.elf
	$(QEMU) $(QFLAGS) uart.elf

qemu-clint: clint.elf
	$(QEMU) $(QFLAGS) clint.elf

clean:
	rm -f *.o *.elf
