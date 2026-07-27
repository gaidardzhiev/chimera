# Hacking

This document describes the repository structure, how to build, and the current implementation status. For the design rationale and architecture overview read [readme.md](./readme.md).

## Repository layout

- chimera/
 - [readme.md](./readme.md) project overview and architecture
 - [hacking.md](./hacking.md) this file
 - [bootstrap.sh](./bootstrap.sh) builds the cross toolchain and kernel image
 - [chimera.cu](./chimera.cu) the CUDA emulator kernel and both drivers
 - [Makefile](./Makefile) builds chimera via nvcc and chimera-cpu via c++
 - [run.sh](./run.sh) device tree generation, image packing, and boot
 - [verify.sh](./verify.sh) the test chain
 - [.gitignore](./.gitignore) excludes all bootstrap build artifacts
 - tests/
   - [Makefile](tests/Makefile) builds and runs the bare-metal test programs
   - [link.ld](tests/link.ld) flat linker script, entry at 0x80000000
   - [uart.s](tests/uart.s) stage one: UART transmit test
   - [clint.s](tests/clint.s) stage two: CLINT timer interrupt test
   - [uart_echo.s](tests/uart_echo.s) stage three: UART receive and echo test
 - tools/
   - [mkdtb.c](tools/mkdtb.c) generates the Chimera flattened device tree

## Building the toolchains

The bootstrap script builds three separate toolchains. Run every stage from the project root.

```sh
./bootstrap.sh dirs
./bootstrap.sh toolchain
./bootstrap.sh toolchain-linux
./bootstrap.sh toolchain-nommu
```

The bare-metal toolchain installs into `sysroot/bin` and produces `riscv32-unknown-elf-gcc`. It is used to build the programs in the tests directory.

The Linux kernel toolchain installs into `sysroot-linux/bin` and produces `riscv32-unknown-linux-gnu-gcc`. It uses glibc and is used only to build the Linux kernel.

The NOMMU userspace toolchain installs into `buildroot-nommu/host/bin` and produces `riscv32-buildroot-linux-uclibc-gcc`. Buildroot 2025.02.15 builds this toolchain with uClibc, RV32IMA, the ILP32 ABI, bFLT support, and elf2flt. It is used to build BusyBox and all later NOMMU userspace programs.

The three compiler prefixes are independent:

```
riscv32-unknown-elf-
riscv32-unknown-linux-gnu-
riscv32-buildroot-linux-uclibc-
```

The bare-metal toolchain is configured with `rv32ima_zicsr_zifencei` and the ILP32 ABI. The Linux and NOMMU toolchains use `rv32ima` and the ILP32 ABI. The Buildroot default configuration enables the F and D extensions and the ILP32D ABI, therefore the bootstrap script removes those settings before building the NOMMU toolchain.

Only add the prefixed Buildroot tool directory to the interactive shell path:

```sh
export PATH="/home/src/1v4n/chimera/buildroot-nommu/host/bin:${PATH}"
```

Do not add `buildroot-nommu/host/riscv32-buildroot-linux-uclibc/bin` to `PATH`. That directory contains unprefixed assembler and linker programs which can replace the host tools.

The NOMMU stage verifies both the compiler and elf2flt. It builds a static test program and rejects the result unless the first four bytes are the bFLT magic `bFLT`.

## Building the Linux test kernel

The kernel is Linux 6.6.35 built with the glibc Linux cross compiler. The userspace libc does not affect the kernel build.

```sh
./bootstrap.sh linux
```

The kernel configuration starts from:

```sh
make rv32_nommu_virt_defconfig
```

Use `rv32_nommu_virt_defconfig`, not `nommu_virt_defconfig`. The RV32 target combines the NOMMU virtual-machine configuration with the required 32-bit RISC-V configuration.

The bootstrap script then enables the formats required by the initramfs and removes the forced root device command line:

```
CONFIG_BINFMT_FLAT=y
CONFIG_BINFMT_SCRIPT=y
CONFIG_CMDLINE=""
# CONFIG_CMDLINE_FORCE is not set
```

The original defconfig forced `root=/dev/vda rw`. That command line discarded the QEMU `rdinit=/sbin/init` argument and made the kernel try to mount a block device which was not present. The kernel now accepts the command line supplied by QEMU.

Verify the important architecture settings:

```sh
grep -E \
'CONFIG_ARCH_RV32I|CONFIG_32BIT|CONFIG_64BIT|CONFIG_MMU|CONFIG_RISCV_M_MODE|CONFIG_RISCV_SBI|CONFIG_BINFMT_FLAT|CONFIG_BINFMT_SCRIPT|CONFIG_CMDLINE' \
.config
```

The configuration must include:

```
CONFIG_32BIT=y
CONFIG_ARCH_RV32I=y
CONFIG_RISCV_M_MODE=y
CONFIG_BINFMT_FLAT=y
CONFIG_BINFMT_SCRIPT=y
CONFIG_CMDLINE=""
# CONFIG_MMU is not set
# CONFIG_CMDLINE_FORCE is not set
```

`CONFIG_RISCV_M_MODE=y` is correct. The kernel executes directly in machine mode and does not use SBI firmware.

The uncompressed kernel image is:

```
kernel/linux-6.6.35/arch/riscv/boot/Image
```

Verify the linked entry address:

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

The QEMU `virt` machine places RAM at `0x80000000`. An RV32 M-mode NOMMU kernel has a zero image offset and starts at the beginning of RAM.

The fixed boot addresses are:

```
QEMU reset ROM       0x00001000
QEMU RAM base        0x80000000
Linux image load     0x80000000
Linux entry point    0x80000000
```

Do not use OpenSBI for this kernel. OpenSBI occupies the beginning of RAM and normally starts an S-mode kernel at a different address. The Chimera test kernel is an M-mode kernel and must be started with `-bios none`.

## Building the NOMMU BusyBox root filesystem

BusyBox is built by Buildroot with the verified NOMMU uClibc toolchain:

```sh
./bootstrap.sh busybox
```

The bootstrap stage writes a minimal BusyBox configuration and passes it to Buildroot through `BR2_PACKAGE_BUSYBOX_CONFIG`. Buildroot controls the complete userspace build path including the compiler, uClibc sysroot, position-independent code, static linking, elf2flt conversion, and applet installation.

The current BusyBox version selected by Buildroot 2025.02.15 is 1.37.0.

Only the applets required for the first root filesystem are enabled:

```
init
hush
sh
cat
echo
ls
mkdir
mknod
mount
umount
dmesg
uname
hostname
sleep
halt
poweroff
reboot
```

Hush is used as the shell. Ash is not enabled.

The required BusyBox settings are:

```
CONFIG_NOMMU=y
CONFIG_STATIC=y
CONFIG_LFS=y
CONFIG_HUSH=y
CONFIG_SHELL_HUSH=y
CONFIG_SH_IS_HUSH=y
# CONFIG_ASH is not set
```

`CONFIG_LFS=y` is required because Buildroot compiles userspace with `_FILE_OFFSET_BITS=64`. Without it BusyBox rejects the build because its `off_t` and `uoff_t` sizes do not match.

Buildroot invokes the BusyBox build with the NOMMU settings required by this target:

```sh
-fPIC
-Wl,-elf2flt=-r
-static
SKIP_STRIP=y
```

The `-r` elf2flt option produces a load-to-RAM bFLT executable. `SKIP_STRIP=y` is required because GNU strip does not recognize the converted bFLT format.

The bootstrap stage copies the Buildroot-installed `bin` and `sbin` trees into `rootfs`. It then verifies that `rootfs/bin/busybox` begins with the bFLT magic:

```
62 46 4c 54
```

The confirmed working BusyBox binary reports:

```
BFLT executable - version 4 ram gotpic
Flags: 0x3 ( Load-to-Ram Has-PIC-GOT )
```

The earlier manual BusyBox 1.36.1 build produced a valid-looking bFLT header but crashed during PID 1 startup. Adding `-fPIC` manually did not fix it. Rebuilding the same minimal userspace through Buildroot produced a working binary. The fault was therefore in the manual BusyBox build path, not in the Linux bFLT loader, the kernel command line, or `CONFIG_BINFMT_FLAT_NO_DATA_START_OFFSET`.

## Building the initramfs image

Build the root filesystem archive after BusyBox has been installed:

```sh
./bootstrap.sh image
```

The image stage creates:

```
rootfs/etc/inittab
rootfs/etc/init.d/rcS
rootfs/dev/console
rootfs/dev/null
rootfs/proc
rootfs/sys
rootfs/tmp
image/rootfs.cpio.gz
```

The root filesystem uses `askfirst` instead of respawning the shell continuously:

```
::sysinit:/etc/init.d/rcS
::askfirst:-/bin/sh
::ctrlaltdel:/sbin/reboot
::shutdown:/bin/umount -a -r
```

The `swapoff` shutdown line is not present because the minimal BusyBox configuration does not include the swap applet.

The startup script mounts proc, sysfs, and devtmpfs, sets the hostname to `chimera`, and prints the system banner.

The archive is sorted before cpio and compressed with `gzip -9n`. The `-n` option omits the gzip timestamp. The confirmed working image is approximately 247 KiB and contains 971 cpio blocks.

Verify the installed BusyBox before booting:

```sh
file rootfs/bin/busybox

buildroot-nommu/host/bin/riscv32-buildroot-linux-uclibc-flthdr \
    -p rootfs/bin/busybox
```

## Running the NOMMU image under QEMU

The bootstrap script contains a QEMU stage:

```sh
./bootstrap.sh qemu
```

It runs the kernel and initramfs with:

```sh
qemu-system-riscv32 \
    -machine virt \
    -cpu rv32 \
    -smp 1 \
    -m 128M \
    -nographic \
    -bios none \
    -kernel kernel/linux-6.6.35/arch/riscv/boot/Image \
    -initrd image/rootfs.cpio.gz \
    -append "earlycon=uart8250,mmio,0x10000000 console=ttyS0,115200 rdinit=/sbin/init"
```

The kernel accepts the QEMU command line, unpacks the initramfs, finds `/sbin/init`, recognizes the bFLT executable, and starts BusyBox as PID 1.

The verified boot reaches:

```
Run /sbin/init as init process
init started: BusyBox v1.37.0
starting pid 21, tty '': '/etc/init.d/rcS'

Chimera RV32 NOMMU

starting pid 29, tty '': '-/bin/sh'
```

Hush then starts successfully and presents an interactive shell:

```
BusyBox v1.37.0 hush - the humble shell
Enter 'help' for a list of built-in commands.

/ #
```

The root filesystem is mounted and accessible:

```
/ # ls
dev   root  bin   etc   proc  sbin  sys   tmp
```

This is the first complete Linux userspace boot for the Chimera RV32 NOMMU target. Linux 6.6.35 reaches PID 1, executes the Buildroot-produced bFLT BusyBox, runs `rcS`, mounts proc, sysfs, and devtmpfs, prints the Chimera banner, and opens an interactive shell.

The temporary `/tmp/hello` test revealed one important filesystem detail. `rootfs/sbin/init` is a symlink to `../bin/busybox`. Copying a test program directly onto that path follows the symlink and overwrites `rootfs/bin/busybox`. A future replacement test must remove the symlink first or write to a separate path.

## Memory map

Guest RAM is one flat window at `0x80000000` of `RAM_SIZE` bytes. An address is decoded as

```
p = addr - 0x80000000            must be below RAM_SIZE, otherwise access fault
p <  RO_SIZE                     shared region, read only, a write faults
p >= RO_SIZE                     private slice at offset p - RO_SIZE
```

The MMIO ranges for the UART at `0x10000000` and the CLINT at `0x02000000` are decoded before RAM and are private to each namespace.

The load addresses are:

```
kernel      0x80000000
initramfs   0x80300000
device tree 0x80400000
```

All three are placed in the RAM template the cpu uploads once. The device fills every private slice from that template above `RO_SIZE`, so the cpu never allocates guest memory per namespace.

`RO_SIZE=0` gives each namespace a complete private copy of the image and shares nothing. This is the default and is what the Linux boot has been verified with.

To share the kernel text, set `RO_SIZE` to the offset of `_etext` rounded down to a page:

```sh
riscv32-unknown-linux-gnu-nm kernel/linux-6.6.35/vmlinux | grep -w _etext
```

Two conditions must hold before that is safe. `CONFIG_RISCV_ALTERNATIVE` must be off, because alternatives patch `.text` in place during boot and would write into the shared region. And `__init_begin` must be above `_etext`, so that `free_initmem`, which does write to that range, stays inside the private slice. Boot a single namespace after changing it. A split placed too high fails immediately and reports the faulting address and program counter:

```
chimera: ns[0] faulted: write to shared read-only region ... addr=0x... fault_pc=0x...
```

The saving is smaller than it appears. The kernel reports 1479K of code against 290K of rwdata, 200K of rodata, 131K of init and 107K of bss, and the initramfs is unpacked into tmpfs inside the private slice rather than executed in place. Sharing the kernel text therefore recovers under ten percent of a 16MB slice. Making the sharing significant requires a read only root filesystem held in the shared region with XIP bFLT execution instead of an initramfs, which is a root filesystem and kernel configuration change rather than an emulator change.

## Building the emulator

The emulator builds two ways from one source file. The CUDA build requires an Nvidia GPU and nvcc. The reference hardware is an RTX 3060 Ti.

```sh
make            # chimera, via nvcc
make cpu       # chimera-cpu, via c++
```

`chimera.cu` compiles as ordinary C++ when `CHIMERA_CPU` is defined. The emulator core is identical in both builds. Only the driver differs: the CUDA build launches one thread per namespace, the cpu build runs a single namespace in the calling process. Nothing about the guest is special cased. A guest that behaves differently under the two builds indicates a CUDA defect rather than an emulation defect, which is the fastest way to narrow a failure.

The compute capability is set by `ARCH` in the Makefile and defaults to `sm_86` for the Ampere architecture of the 3060 Ti. Change it to match the card.

Two Makefile variables define the guest memory map and are passed to both builds:

```
RAM_SIZE=33554432    guest RAM window at 0x80000000
RO_SIZE=0            leading bytes of that window shared across namespaces
```

`RAM_SIZE` must match the memory node in the device tree. `run.sh` passes the same value to `mkdtb`, so the two cannot drift apart. Linux with the BusyBox initramfs requires at least 16MB and will not reach a shell below that; 32MB is comfortable. `RO_SIZE` is described under Memory map below.

## Running the emulator

The emulator takes either a flat bare-metal binary or a kernel, initramfs and device tree, followed by a namespace count.

```sh
./chimera binary.bin N
./chimera kernel.bin initrd.bin chimera.dtb N
```

`run.sh` wraps the kernel path and keeps the load addresses, the memory size and the timebase consistent between the device tree and the emulator:

```sh
./run.sh mkdtb
./run.sh pack
./run.sh boot 1        # CUDA build
./run.sh cpuboot      # cpu build, single namespace
```

Console output from namespace 0 is streamed to stderr as the run proceeds. The complete output buffer of every namespace is written to stdout in namespace order when the run ends, so batch collection remains deterministic regardless of how the hardware scheduled the warps.

Standard input is fed to the UART receive path of namespace 0. When stdin is a terminal it is placed in raw mode and the guest gets a live interactive console; ctrl-] detaches and ends the run. When stdin is a pipe the bytes are queued in the receive ring and consumed by the guest as it reads them. Namespaces other than 0 receive no input.

Two environment variables control execution:

```
CHIMERA_MAX_STEPS   total instruction budget for the run, default 500000000
CHIMERA_CHUNK       instructions per kernel launch, default 20000000
```

A booted Linux never terminates, so the step budget is what ends the run. The default is roughly eight seconds of guest time at the configured timebase, which reaches a shell with headroom. Raise it for interactive use.

The chunk is how far the CUDA kernel runs before returning to the cpu. All machine state lives in device memory across launches, so relaunching costs only launch overhead and loses no progress. The chunk matters for two reasons. Output is drained and input is collected only between launches, so a large chunk makes an interactive console unusable. And if the card is also driving a display, the driver watchdog terminates any launch that runs longer than about two seconds, which appears as `launch failed: the launch timed out and was terminated`. Lower the chunk until each launch fits inside the watchdog window. Two hundred thousand is a reasonable value for interactive work.

## Verification

`verify.sh` runs the whole chain. The CUDA tests are skipped when nvcc is absent, so the same script is useful on a machine without a card.

```sh
./verify.sh
NS=64 STEPS=800000000 ./verify.sh
```

```
ft1  the cpu emulator builds
ft2  a 36 byte hand assembled binary prints ok and exits in exactly 9 steps
ft3  the generated device tree is a well formed flattened device tree
ft4  Linux reaches init, then the rcS banner, then a shell prompt
ft5  two cpu boots are byte identical
ft6  a store into the shared region faults the namespace at the right address
ft10 typed input on a real terminal reaches the guest shell
ft7  the CUDA emulator builds
ft8  a one namespace CUDA boot is byte identical to the cpu boot
ft9  N namespaces each produce a complete and identical boot log
```

ft2 requires no RISC-V toolchain. The binary is written by the script and exercises LUI, ADDI, SB, the UART transmit path and the `mtvec` unset ecall exit contract, so a decode regression is caught before anything larger runs.

ft5 and ft8 are the pair that matter. Guest time is derived from a retired instruction counter rather than from wall clock, so a Chimera boot is fully deterministic. ft5 establishes that, and ft8 then compares a CUDA boot against the cpu boot byte for byte. Any difference is a race, a stray pointer or an unfilled slice on the device rather than an emulation error.

ft10 drives the emulator through a pseudo terminal with script, waits for the prompt, types an arithmetic expansion and requires the result to appear in addition to the echo of the typed line. A piped stdin test cannot substitute for it: on a terminal in non-canonical mode a read with no data pending returns zero rather than EAGAIN, which is indistinguishable from end of file unless the descriptor is known to be a terminal. Treating it as end of file disables input for the rest of the run, and the failure is invisible to any test that feeds input through a pipe.

ft9 checks both that every namespace reached userspace and that the total output is exactly N times a single log, which detects slices overlapping.

The bare-metal programs still run under QEMU against the virt machine, which uses the same UART and CLINT addresses, and the same binaries converted with objcopy are the first inputs to the emulator:

```sh
cd tests && make && cd ..
riscv32-unknown-elf-objcopy -O binary tests/uart.elf uart.bin
./chimera-cpu uart.bin 1
./chimera uart.bin 4000
```

A binary that produces correct output under QEMU and incorrect output under Chimera indicates a defect in the emulator.

## Benchmarks

The measurements previously recorded here were taken before the cpu driver was corrected and no longer describe the emulator. They were dominated by the cpu side allocation: `ns_t` embedded the entire private slice, so the driver allocated, uploaded and downloaded the whole guest memory of every namespace. The reported figure of approximately 2.2MB of cpu RAM per namespace is exactly `SLICE_SIZE`, and the linear time scaling was the cost of that copy rather than of emulation.

Private slices are now allocated on the device and filled there from a single uploaded template. The cpu holds only the `ns_t` array, which is the register file, the CSR set and the IO buffers. The benchmark must be taken again.

The figures worth recording are the wall clock of a complete boot to a shell at one namespace against the same boot at 64 and at 256, and the retired instructions per second implied by each. A single GPU thread is considerably slower at branchy interpretation than a CPU core, so the one namespace case is expected to lose to the cpu build by a wide margin. The architectural claim in readme.md is about aggregate throughput, and it stands or falls on whether the 256 namespace case costs substantially more wall clock than the one namespace case.

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

Constants and type definitions: `RAM_SIZE`, `RO_SIZE`, the load addresses and the MMIO bases are defined at the top. `cpu_t` holds the register file, the CSR set, the current privilege level and the fault record for one namespace. `ns_t` holds `cpu_t`, the UART register file and the IO buffers. The private slice is no longer a member of `ns_t`; it is a separate device allocation indexed by thread.

Memory access: `ram_off` decodes an address and its full access width against the RAM window, `ram_ptr` selects the shared region or the private slice, and `mem_read` and `mem_write` handle 1, 2 and 4 byte accesses. A write below `RO_SIZE` sets the done flag, records the faulting address and program counter, and terminates the namespace.

MMIO dispatch: `mmio_read` and `mmio_write` implement the NS16550 register file including the divisor latch, the scratch register and the interrupt identity register, which the 8250 autoconfiguration path requires in order to recognise the part, together with the CLINT `mtime` and `mtimecmp` registers. `is_mmio` gates all load and store operations.

Timer and interrupt: `device_tick` advances `mtime` by `TIMER_QUANTUM` on every retired instruction and recomputes the machine timer pending bit as a level signal from `mtime` against `mtimecmp`. `interrupt_check` delivers a pending interrupt before the next fetch, and takes account of the current privilege level: machine interrupts are enabled unconditionally while the hart is below machine mode.

Traps: `trap` implements the machine mode trap entry for exceptions and interrupts, stacking the privilege level into `MPP` and the interrupt enable into `MPIE`, recording `mcause` and `mtval`, and honouring vectored mode. `MRET` restores both.

CSR access: `csr_read` and `csr_write` centralise all CSR access and enforce the read only bits of `mip`.

Compressed instructions: `decompress` expands a 16 bit instruction into the equivalent 32 bit encoding, which the ordinary decoder then executes. The kernel image is built with the C extension regardless of the toolchain configuration, so this path carries the majority of the instructions executed during a boot.

Fetch decode execute: the main decode loop. It reads a halfword, decompresses it or reads the second halfword, decodes the fixed fields and dispatches on opcode. Implements the full RV32I base ISA, the complete M extension, the A extension without atomicity, the Zicsr and Zifencei instructions, and the machine mode privileged instructions.

`run_slice`: the bounded execution loop. It retires at most a given number of instructions and returns, so a namespace that never terminates cannot hang a kernel launch.

Chimera kernels: `chimera_fill` initialises every private slice from the uploaded RAM template. `chimera_step` runs one namespace per thread for one chunk.

CPU driver: `main` loads the images into the template with bounds checking, initialises the namespace array, uploads once, then launches `chimera_step` repeatedly, draining console output and collecting console input between launches, until every namespace is done or the step budget is exhausted.

## Implementation status

Linux 6.6.35 boots to an interactive Hush shell under the emulator, on the CUDA build on an RTX 3060 Ti and on the cpu build. The console is interactive in both.

The RV32I base integer ISA is fully implemented. The M extension is fully implemented. The C extension is implemented by expansion to the equivalent 32 bit encodings. The A extension is stubbed with a non-atomic load store pair, which is sufficient while each namespace is a single hart and will not be sufficient once the NIC controller introduces shared state. Machine and user privilege levels are implemented, which the NOMMU port requires: the kernel runs in machine mode and userspace runs in user mode, and the kernel distinguishes them by `MPP`. Trap entry and return, `mcause`, `mtval`, and the `MIE` and `MPIE` stacking are implemented. The CLINT timer is implemented. The NS16550 is implemented to the extent the 8250 autoconfiguration path probes.

The UART carries no interrupt line. Chimera implements no PLIC, and a device cannot be wired directly to the hart local external interrupt, because riscv-intc maps its interrupts as per-CPU devids and `request_irq` from the 8250 driver fails. The device tree therefore declares no interrupt for the port and the driver runs it timer polled, which is consistent with the hardware model in readme.md. A PLIC becomes necessary at the NIC controller stage.

The virtio-net NIC controller is not implemented. The MMIO range returns zero on read and discards writes.

Input is delivered to namespace 0 only. The batch model in readme.md requires per-namespace input, which is not yet implemented.

The bare-metal ELF toolchain, Linux glibc toolchain, and Buildroot uClibc NOMMU toolchain are built and verified. The NOMMU toolchain produces static RV32 bFLT executables.

Linux 6.6.35 builds correctly for RV32 NOMMU M-mode and boots both under QEMU and under Chimera. Buildroot 2025.02.15 builds BusyBox 1.37.0 with the minimal Chimera configuration. The resulting RAM-loaded GOTPIC bFLT binary starts as PID 1, executes `/etc/init.d/rcS`, mounts proc, sysfs and devtmpfs, sets the hostname, and opens an interactive Hush shell.

The first complete RV32 NOMMU Linux boot on GPU hardware is accomplished. The kernel, initramfs, bFLT loader, uClibc userspace, BusyBox init, startup script, device files, mounted virtual filesystems, serial console, and interactive shell are all verified under the emulator.
