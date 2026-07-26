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

Buildroot 2025.02.15 builds BusyBox 1.37.0 with the minimal Chimera configuration. The resulting RAM-loaded GOTPIC bFLT binary starts as PID 1, executes `/etc/init.d/rcS`, mounts proc, sysfs, and devtmpfs, sets the hostname, and opens an interactive Hush shell.

The deterministic initramfs image builds successfully. The confirmed working image is approximately 247 KiB and contains 971 cpio blocks.

The first complete RV32 NOMMU Linux userspace boot is accomplished. The kernel, initramfs, bFLT loader, uClibc userspace, BusyBox init, startup script, device files, mounted virtual filesystems, serial console, and interactive shell are all verified under QEMU.
