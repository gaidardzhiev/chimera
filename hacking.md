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

BusyBox 1.36.1 is built with the Buildroot NOMMU compiler:

```sh
./bootstrap.sh busybox
```

The build starts from `allnoconfig`. Only the applets required for the first root filesystem are enabled:

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

Hush is used as the shell. Ash is not enabled because the BusyBox ash implementation is not suitable for this NOMMU configuration.

The required BusyBox settings are:

```
CONFIG_NOMMU=y
CONFIG_STATIC=y
CONFIG_HUSH=y
CONFIG_SH_IS_HUSH=y
# CONFIG_ASH is not set
# CONFIG_SH_IS_ASH is not set
```

BusyBox 1.36.1 provides `oldconfig`, not `olddefconfig`. The bootstrap script feeds the default answers to `oldconfig` after editing `.config`.

The final executable is converted to a RAM-loaded position-independent bFLT image with:

```sh
CONFIG_EXTRA_LDFLAGS="-Wl,-elf2flt=-r"
```

The `-r` elf2flt option produces a load-to-RAM bFLT binary. `SKIP_STRIP=y` is required because GNU strip does not recognize the already converted bFLT file. The same linker flags and `SKIP_STRIP=y` must be passed to both the build and install commands. Otherwise `make install` can relink BusyBox as ELF and replace the verified bFLT binary.

The script verifies the first four bytes of both the build-tree binary and the installed `rootfs/bin/busybox`. Both must contain:

```
62 46 4c 54
```

The installed binary currently reports:

```
BFLT executable - version 4 ram gotpic
Flags: 0x3 ( Load-to-Ram Has-PIC-GOT )
```

The missing `pod2man` and `pod2html` commands only prevent BusyBox documentation from being generated. Those errors are ignored by the BusyBox build and do not affect the executable.

The warning in `shell/hush.c` about `exp_word` being used uninitialized is a compiler warning and is not the current boot blocker.


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

The archive is sorted before cpio and compressed with `gzip -9n`. The `-n` option omits the gzip timestamp. The current minimal image is approximately 113 KiB and contains 452 cpio blocks.

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

The kernel now accepts the QEMU command line, unpacks the initramfs, finds `/sbin/init`, recognizes the bFLT format, and starts the BusyBox process.

The current boot reaches:

```
Run /sbin/init as init process
```

BusyBox then receives signal 11:

```
init[1]: unhandled signal 11 code 0x2 at 0x8059ef0c
badaddr: 000373bc cause: 00000007
Kernel panic - not syncing: Attempted to kill init! exitcode=0x0000000b
```

This is no longer a missing root filesystem, forced command line, missing bFLT loader, or ELF installation problem. The kernel has executed the bFLT entry point and the failure occurs in userspace during BusyBox startup.

The fault address `0x000373bc` lies immediately below the BusyBox data end `0x000373f8`. The next investigation must determine whether a BusyBox pointer or GOT entry remains unrelocated, or whether the BusyBox build requires an additional NOMMU-specific compiler setting.

The Linux 6.6.35 source already contains the RISC-V bFLT GOT header handling in `fs/binfmt_flat.c` through `skip_got_header()`. `CONFIG_BINFMT_FLAT` and `CONFIG_BINFMT_SCRIPT` are enabled.

A temporary minimal bFLT test was attempted by copying `/tmp/hello` to `rootfs/sbin/init`. This path is a symlink to `../bin/busybox`, therefore ordinary `cp` followed the symlink and overwrote `rootfs/bin/busybox`. The matching headers observed afterward belonged to the same test binary and did not compare BusyBox against the test program. Do not copy a test program onto `rootfs/sbin/init` without first removing the symlink and preserving the BusyBox binary.


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

The bare-metal ELF toolchain, Linux glibc toolchain, and Buildroot uClibc NOMMU toolchain are built and verified. The NOMMU toolchain produces static RV32 bFLT executables.

Linux 6.6.35 builds correctly for RV32 NOMMU M-mode and boots under QEMU with console output. The kernel entry point is `0x80000000`. The forced `root=/dev/vda` command line has been removed. The kernel accepts the supplied initramfs command line, unpacks `rootfs.cpio.gz`, finds `/sbin/init`, and executes the bFLT loader.

BusyBox 1.36.1 builds as a static RAM-loaded PIC bFLT binary and installs the minimal applet set into rootfs. The deterministic initramfs image builds successfully and is approximately 113 KiB.

The current blocker is the BusyBox PID 1 startup fault. The process begins execution and then receives signal 11 with `badaddr 0x000373bc`. The fault is inside the BusyBox data boundary and is under investigation as a bFLT relocation, GOT, or BusyBox NOMMU build issue. The kernel, initramfs discovery, bFLT recognition, and executable entry path are verified.
