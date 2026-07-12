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

The bootstrap script builds the riscv32-unknown-elf cross toolchain from the riscv-gnu-toolchain repository. Run it from the project root.

```sh
./bootstrap.sh dirs
```

```sh
./bootstrap.sh toolchain
```

The toolchain installs into sysroot/bin. After the build completes the script prints the PATH export line to add to your shell rc. All subsequent stages depend on the cross toolchain being in PATH. The full chain including the Linux kernel image and busybox rootfs is not yet built. Those stages exist in the script but depend on a Linux-capable toolchain that will be added in a future bootstrap stage.


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


## Building and running the tests

The tests directory contains three bare-metal RV32I programs that verify the emulator and the toolchain independently of the Linux kernel. They run under qemu-system-riscv32 against the virt machine, which uses the same UART and CLINT addresses as Chimera.

```sh
cd tests
make
```

Build targets produce .elf files. Run targets launch QEMU.

```sh
make qemu-uart      #prints chimera and exits
make qemu-clint     #prints tick repeatedly on each timer interrupt
make qemu-uart-echo  #prints chimera uart echo ready then echoes input
```
**Exit QEMU with Ctrl-A X.**

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

The Linux kernel build stage is not yet complete. The current toolchain is bare-metal ELF. A Linux-capable glibc toolchain will be added to bootstrap.sh when the emulator is verified correct against the bare-metal test suite.
