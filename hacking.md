# Hacking

This document describes the repository structure, how to build, and the current implementation status. For the design rationale and architecture overview read [readme.md](./readme.md).


## Repository layout

- chimera/
 - [readme.md](./readme.md) project overview and architecture
 - [hacking.md](./hacking.md) this file
 - [bootstrap.sh](./bootstrap.sh) builds the cross toolchain and kernel image
 - [chimera.cu](./chimera.cu) the CUDA emulator kernel and host driver
 - [Makefile](./Makefile) builds chimera from chimera.cu via nvcc
 - [.gitignore](./.gitignore) excludes all bootstrap build artifacts
 - tests/
   - [Makefile](tests/Makefile) builds and runs the bare-metal test programs
   - [link.ld](tests/link.ld) flat linker script, entry at 0x80000000
   - [uart.s](tests/uart.s) stage one: UART transmit test
   - [clint.s](tests/clint.s) stage two: CLINT timer interrupt test
   - [uart_echo.s](tests/uart_echo.s) stage three: UART receive and echo test


## Building the toolchain

The bootstrap script builds two toolchains from the riscv-gnu-toolchain repository. Run all stages from the project root.

```sh
./bootstrap.sh dirs
./bootstrap.sh toolchain
./bootstrap.sh toolchain-linux
```

The bare-metal toolchain installs into sysroot/bin and produces riscv32-unknown-elf-gcc. It is used to build the tests directory programs. The Linux toolchain installs into sysroot-linux/bin and produces riscv32-unknown-linux-gnu-gcc. It is used to build the kernel and busybox.

The bare-metal toolchain is configured with rv32ima_zicsr_zifencei and ilp32 ABI. The Linux toolchain is configured with rv32ima and ilp32 ABI. glibc requires plain rv32ima and does not accept the extended extension string.

After each build completes the script prints the PATH export line to add to your shell rc. Both sysroot/bin and sysroot-linux/bin must be in PATH for the linux and busybox stages to work.

The toolchain-linux stage reconfigures the existing riscv-gnu-toolchain clone and runs make linux. It does not re-clone. Run toolchain first, then toolchain-linux.

## Building the Linux test kernel

The kernel build uses the Linux cross toolchain. Download Linux 6.6.35 and extract it into the kernel directory:

```sh
mkdir -p kernel

cd src

wget -c \
    https://cdn.kernel.org/pub/linux/kernel/v6.x/linux-6.6.35.tar.gz

tar -xzf linux-6.6.35.tar.gz -C ../kernel
rm linux-6.6.35.tar.gz

cd ../kernel/linux-6.6.35
```

Configure the kernel for RV32, NOMMU, and the QEMU `virt` machine:

```sh
export ARCH=riscv
export CROSS_COMPILE=riscv32-unknown-linux-gnu-

make mrproper
make rv32_nommu_virt_defconfig
```

Use `rv32_nommu_virt_defconfig`, not `nommu_virt_defconfig`. The RV32 target combines the NOMMU virtual-machine configuration with the required 32-bit RISC-V configuration.

Verify the important settings:

```sh
grep -E \
'CONFIG_ARCH_RV32I|CONFIG_32BIT|CONFIG_64BIT|CONFIG_MMU|CONFIG_RISCV_M_MODE|CONFIG_RISCV_SBI' \
.config
```

The configuration must include:

```
CONFIG_32BIT=y
CONFIG_ARCH_RV32I=y
CONFIG_RISCV_M_MODE=y
# CONFIG_MMU is not set
```

`CONFIG_RISCV_M_MODE=y` is correct. The kernel executes directly in machine mode and does not use SBI firmware.

Build the uncompressed kernel image:

```sh
make -j4 Image
```

The output is:

```
arch/riscv/boot/Image
```

Verify the linked entry address before running QEMU:

```sh
riscv32-unknown-linux-gnu-readelf -h vmlinux |
    grep 'Entry point address'

riscv32-unknown-linux-gnu-nm -n vmlinux |
    grep -E ' [Tt] _start$'
```

Expected output:

```
Entry point address:               0x80000000
80000000 T _start
```

The QEMU `virt` machine places RAM at `0x80000000`. An RV32 M-mode NOMMU kernel has a zero image offset and therefore starts at the beginning of RAM.

Test the kernel:

```sh
rm -f qemu-in_asm.log

timeout 3s qemu-system-riscv32 \
    -machine virt \
    -cpu rv32 \
    -smp 1 \
    -m 128M \
    -nographic \
    -bios none \
    -kernel arch/riscv/boot/Image \
    -d in_asm,guest_errors \
    -D qemu-in_asm.log
```

The kernel should initialize the CPU, memory allocator, interrupt controller, CLINT timer, and UART. A successful test reaches the root filesystem stage and ends with:

```
VFS: Cannot open root device "/dev/vda"
Kernel panic - not syncing: VFS: Unable to mount root fs
```

This panic is expected. No virtual block device or root filesystem was supplied to QEMU. It confirms that the kernel was loaded at `0x80000000`, entered in M-mode, initialized the QEMU `virt` machine, and reached PID 1 startup.

The fixed boot addresses are:

```
QEMU reset ROM       0x00001000
QEMU RAM base        0x80000000
Linux image load     0x80000000
Linux entry point    0x80000000
```

Do not use OpenSBI for this kernel. OpenSBI occupies the beginning of RAM and normally starts an S-mode kernel at a different address. The Chimera test kernel is an M-mode kernel and must be started with:

```
-bios none
```


## Building the emulator

The emulator requires an Nvidia GPU with CUDA support and nvcc installed. The reference hardware is an RTX 3060 Ti.

```sh
make
```

This produces the chimera binary at the project root. The compute capability is hardcoded to sm_86 in the Makefile, which targets the Ampere architecture of the 3060 Ti. Change this to match your card if different.


## Running the emulator

The emulator takes a flat binary and a namespace count.

```sh
./chimera binary.bin N
```

The binary is loaded into the shared read-only region at ENTRY_POINT (0x80000000). N namespaces are launched simultaneously, each running the same binary. Output from all namespaces is collected in deterministic order and written to stdout.

To produce a flat binary from the test ELF files use objcopy:

```sh
riscv32-unknown-elf-objcopy -O binary tests/uart.elf uart.bin
./chimera uart.bin 1
```

A correct run prints chimera once. With N=4000 it prints chimera four thousand times.


## Benchmarks

The following measurements were taken on the reference hardware, an RTX 3060 Ti with 8GB GDDR6 VRAM. The binary under test is uart.bin, the flat binary produced from tests/uart.s via objcopy. It prints the string "chimera" to the NS16550 UART and exits. This is a bare-metal program with no Linux kernel involved. It exercises the RV32I decode loop, the UART transmit path, and the namespace isolation mechanism, nothing more.

```sh
for n in 1 10 100 500 1000 2000 3000; do
    /usr/bin/time -f "$n namespaces: %e seconds, %M KiB host RAM" \
        ./chimera uart.bin "$n" >/dev/null
done
```

```
1    namespaces:  0.31 seconds,  101996 KiB host RAM
10   namespaces:  0.28 seconds,  121784 KiB host RAM
100  namespaces:  0.64 seconds,  317572 KiB host RAM
500  namespaces:  2.47 seconds, 1187976 KiB host RAM
1000 namespaces:  4.32 seconds, 2276144 KiB host RAM
2000 namespaces:  8.65 seconds, 4452340 KiB host RAM
3000 namespaces: 12.66 seconds, 6628436 KiB host RAM
```

Scaling is linear. From 1000 to 2000 namespaces time doubles from 4.32 to 8.65 seconds. From 2000 to 3000 it adds the same 4.3 seconds again. Host RAM scales proportionally at approximately 2.2MB per namespace, consistent with the configured SLICE_SIZE. No serialization points between namespaces are visible in the data.

These numbers do not represent Linux namespace performance. They represent the emulator core under a minimal bare-metal workload. Linux kernel boot and the full namespace stack are not yet implemented. The linear scaling result confirms the architectural property that matters before that work begins: namespaces are independent and the GPU scheduler handles them without contention.


## Building and running the tests

The tests directory contains three bare-metal RV32I programs that verify the emulator and the toolchain independently of the Linux kernel. They run under qemu-system-riscv32 against the virt machine, which uses the same UART and CLINT addresses as Chimera.

```sh
cd tests
make
```

Build targets produce .elf files. Run targets launch QEMU.

```sh
make qemu-uart       # prints chimera and exits
make qemu-clint      # prints tick repeatedly on each timer interrupt
make qemu-uart-echo  # prints chimera uart echo ready then echoes input
```

Exit QEMU with Ctrl-A X.

The same binaries converted to flat format with objcopy are the first inputs to the CUDA emulator. A binary that produces correct output under QEMU and incorrect output under Chimera indicates a bug in the emulator.


## Source map

[chimera.cu](./chimera.cu) is the emulator. The structure from top to bottom:

Constants and type definitions: SLICE_SIZE, SHARED_SIZE, ENTRY_POINT, and the MMIO base addresses are defined at the top. cpu_t holds the register file and CSR set for one namespace. ns_t holds the complete mutable state of one namespace including its private memory slice, IO buffers, and cpu_t.

Memory access: mem_read32, mem_read8, mem_write32, mem_write8 dispatch between the shared read-only region and the private slice. A write to the shared region sets the done flag and terminates the namespace.

MMIO dispatch: mmio_read and mmio_write handle the UART and CLINT register surfaces. is_mmio gates all load and store operations.

Timer and interrupt: timer_tick advances mtime by TIMER_QUANTUM on every fetch iteration and sets the timer pending bit in mip when mtime reaches mtimecmp. interrupt_check delivers the interrupt to mtvec before the next fetch if mstatus and mie permit.

CSR access: csr_read and csr_write centralize all CSR access covering mstatus, mie, mip, mtvec, mscratch, mepc, and mcause.

Fetch decode execute: this is the main decode loop, that fetches one instruction, decodes the fixed RV32I fields, dispatches on opcode. Implements the full RV32I base ISA and the complete M extension.

Chimera kernel: The CUDA device kernel. One thread per namespace. Initializes pc to ENTRY_POINT and runs the fetch loop until the done flag is set.

Host driver: main loads the flat binary into the shared region, allocates and initializes N namespace structs, launches the kernel, collects output, and writes it to stdout.


## Implementation status

The RV32I base integer ISA is fully implemented. The M extension is fully implemented. The A extension atomics are stubbed in opcode 0x2f with a non-atomic load-store pair sufficient for single-threaded use. CSR access covers the M-mode registers required for interrupt handling. The UART transmit and receive paths are implemented. The CLINT timer is implemented. The virtio-net NIC controller is not yet implemented, the MMIO range returns zero on read and discards writes.

The bare-metal ELF toolchain is built and verified. The Linux glibc toolchain is built and verified. The Linux 6.6.35 kernel builds correctly with nommu_virt_defconfig using riscv32-unknown-linux-gnu-gcc. The kernel executes under QEMU confirmed via instruction trace showing the reset ROM at 0x1000 jumping to 0x80000000 and the kernel initializing. Console output from the kernel under QEMU is not yet resolved, the kernel runs but produces no terminal output. This is a QEMU invocation issue under investigation, not a kernel or emulator bug. The bootstrap.sh linux stage has not yet been reconciled with the manual build process and should not be used until it is updated.
