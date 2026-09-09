# Chimera

Chimera is a massively parallel RISC-V emulator running on Nvidia GPU hardware. It boots a NOMMU RV32 Linux kernel image and multiplexes many isolated machine namespaces on top of it, one per CUDA thread. Each namespace has its own register file, CSR set, private writable memory, console and output buffer. A configurable read-only prefix of guest RAM is shared across every namespace simultaneously, a write to it faults the offending namespace and terminates it, while the others continue.

Linux 6.6.35 boots to an interactive shell under this emulator, on the CUDA build on an RTX 3060 Ti. The result is hundreds of structurally isolated Linux machines on one GPU card, each believing it owns the hardware, none of them able to affect any other in theory.


## The Problem

Linux containers on a CPU share a kernel but isolate process state through namespace and cgroup machinery built into the kernel itself. The isolation is a policy enforced by software. It works, but each container still requires its own kernel scheduler, memory allocator context, device driver surface so the overhead per container accumulates.

Running thousands of fully isolated environments on one machine today means either thousands of containers with nontrivial per-container overhead, or thousands of virtual machines with even higher overhead. Neither scales to the thread counts a modern GPU makes available.

Chimera approaches the problem differently, by puting the isolation boundary in the emulator, not the kernel. The kernel inside does not know it is being multiplied because it sees one machine, and the emulator provides thousands of private address spaces on top of one shared kernel image, and the GPU's own hardware scheduler keeps the execution units busy while individual namespaces stall on memory or block on IO.


## Memory Layout

VRAM is divided into two regions before the kernel launches.

Guest RAM is one flat window at 0x80000000 of RAM_SIZE bytes, exactly as a real machine presents it. The window is split at RO_SIZE, everything below the split is the shared region, read only, one copy for the whole card. Everything at or above it is the namespace's private slice, mapped into the guest address space at its natural address rather than at zero, so that the kernel's own data and bss land in private memory without the kernel knowing anything has been divided.

    guest physical:
    [ 0x80000000                shared RO, RO_SIZE bytes       ]
    [ 0x80000000 + RO_SIZE      private RW, RAM_SIZE - RO_SIZE ]

    VRAM:
    [ RAM template              RAM_SIZE, uploaded once        ]
    [ private slice: ns 0       RAM_SIZE - RO_SIZE             ]
    [ private slice: ns 1       RAM_SIZE - RO_SIZE             ]
    [ private slice: ns 2       ...                            ]
    [ NIC controller 0..M       fixed region, not implemented  ]

The CPU uploads one RAM template holding the kernel, the initramfs and the device tree, and a device kernel fills every private slice from it. It never allocates guest memory per namespace. Reads from the shared region require no synchronization, writes to it are caught by a range check in the memory access path and fault the namespace immediately, recording the faulting address and program counter.

`RO_SIZE` defaults to zero, which gives each namespace a complete private copy and shares nothing. That is what the Linux boot is verified with. Raising it to the offset of the kernel's `_etext` shares the kernel text, which is genuinely read-only after the image is built, provided alternatives patching is disabled and the init sections that `free_initmem` writes to stay above the split.

The honest arithmetic is less favourable than it first appeard... The kernel reports 1479K of code against 290K of rwdata, 200K of rodata, 131K of init and 107K of bss, and the initramfs is unpacked into tmpfs inside the private slice rather than executed in place, so it costs every namespace a second time. Sharing the kernel text therefore recovers under ten percent of a slice. Booting at decreasing `RAM_SIZE` puts the floor for this rootfs at 16MB: 24MB and 16MB reach a shell, 12MB does not, and 10MB panics with no working init. On 8GB that is roughly 450 to 480 namespaces rather than thousands. Making the sharing significant means replacing the initramfs with a read-only root held in the shared region and executed in place, which is a root filesystem and kernel configuration change rather than an emulator change.


## Emulated Hardware

Chimera emulates a minimal RV32I machine sufficient to boot NOMMU Linux and run processes under it. The emulated hardware surface is small by design.

The CPU implements the RV32I base integer instruction set with the register file of 32 32-bit registers and x0 hardwired to zero. The M extension is implemented in full because the kernel and uClibc require it. The C extension is implemented by expanding each compressed encoding into its 32 bit equivalent before decode, which is not optional: the kernel adds the C extension to its own march irrespective of how the toolchain was configured, and 62 percent of the instructions in its text are compressed. The A extension is present as a non-atomic load store pair, which is sufficient while a namespace is a single hart and will not be sufficient once the NIC controller introduces shared state.

Privileged mode covers machine mode and user mode. Machine mode alone is not sufficient: the NOMMU port runs the kernel in machine mode but runs userspace in user mode, and distinguishes the two by MPP, so a machine without privilege levels sees every userspace syscall arrive as an environment call from machine mode and panics PID 1 on the first one. Trap entry and return are implemented with mcause, mtval and the MIE and MPIE stacking, along with the rule that machine interrupts are delivered unconditionally while the hart is below machine mode. The implemented CSRs are mstatus, mie, mip, mepc, mcause, mtvec, mscratch and mtval. There is no MMU and no address translation. Virtual addresses are physical addresses.

The CLINT provides mtime and mtimecmp as MMIO registers. The emulator advances mtime by a fixed quantum for every retired instruction and recomputes the machine timer pending bit as a level signal from mtime against mtimecmp. The quantum and the timebase-frequency in the device tree are two halves of one number and must agree, or the kernel's sense of time is wrong by whatever factor separates them and every timeout in it fires at once. This is the mechanism by which the Linux scheduler receives its timer ticks.

The UART is an NS16550-compatible device. The transmit register appends to the namespace's output buffer and the receive register consumes from its input ring. The interrupt identity, line control, modem control and scratch registers and the divisor latch are modelled as well, not for their own sake but because the 8250 autoconfiguration path probes them to identify the part, and a device that does not answer is not registered as a console at all.

No other devices are emulated beyond what the networking section describes. No PCI bus, no block device, no interrupt controller beyond the CLINT. One consequence is worth stating plainly, because it is not obvious: with no PLIC, the UART has no interrupt line. A device cannot be wired straight to the hart-local external interrupt, because riscv-intc registers its interrupts as per-CPU devids and request_irq from the 8250 driver fails. The device tree therefore declares no interrupt for the port and the driver runs it timer polled. A PLIC becomes necessary at the NIC controller stage.


## Isolation

Isolation between namespaces is structural. Each namespace has its own private memory slice. There is no shared mutable state between namespaces unless explicitly arranged by the host before launch. A namespace cannot address another namespace's private memory because its address space does not contain it.

The shared region is the only memory visible to all namespaces simultaneously, and it is read-only after launch. A write to it is a fault. The faulting namespace is marked done and stops, and the emulator records the cause, the faulting address and the program counter so the split can be diagnosed. Its output up to that point is still collected. No signal is sent to other namespaces. They do not observe the fault.

A runaway allocation that exhausts the private heap arena, a stack overflow, a division by zero, an infinite loop: none of these affect any namespace but the one in which they occur. The others finish and their output is collected normally.

This isolation is stronger than what Linux containers provide on a CPU. Containers share a kernel. A kernel bug or a privilege escalation that reaches the kernel affects all containers on the host. Under Chimera the kernel is a read-only artifact. The emulator is the isolation boundary. A misbehaving namespace cannot affect the emulator itself because the emulator runs in CUDA device code outside the address space the namespace can reach.


## IO

Execution is bounded and resumable. A kernel launch retires at most a fixed number of instructions per namespace and returns, and because all machine state lives in device memory across launches, relaunching costs only launch overhead and loses no progress. This is not a refinement, it is what makes a Linux guest observable at all: a booted kernel idling at a shell never terminates, so a run-to-completion model can never see a successful boot, and an unbounded device loop is a hang that the display driver watchdog eventually kills.

Input is a ring per namespace, produced by the cpu and consumed by the guest. Between launches the cpu reads whatever is available on standard input and appends it, then uploads the namespace. When standard input is a terminal it is placed in non-canonical mode and the guest gets a live interactive console, which is how a shell inside a namespace is usable at all. Input is delivered to namespace 0 only. Per-namespace input, which the batch model wants, is not yet implemented.

Output is accumulated in the namespace's output buffer through the UART transmit path, and namespace 0 is streamed as the run proceeds. The complete buffer of every namespace is written out in namespace order when the run ends, so batch collection stays deterministic regardless of how the hardware scheduled the warps. The buffer has a fixed maximum size defined at compile time, and a namespace that overruns it currently loses the excess silently, which the transmit path should report instead.


## Networking

Networking is provided by dedicated NIC controller threads that run inside the same CUDA kernel launch as the namespace threads. A NIC controller is not a namespace. It does not run a fetch-decode-execute loop and it does not emulate a CPU. It runs a packet dispatch loop: read from an ingress ring fed by the host, inspect the destination address, write the packet into the correct namespace's RX ring, set the interrupt pending flag in that namespace's private region. For egress it drains each namespace's TX ring and writes outbound packets into a host-mapped egress buffer. The host process on the CPU side is a thin bridge to a real network interface or a TAP device. The routing intelligence lives in the controller thread on the GPU, not on the host.

Each namespace sees a virtio-net device at a fixed MMIO address. The virtio-net driver is already present in the Linux kernel and requires no modification. The namespace writes outbound packets into descriptor rings at that address. The NIC controller is the only entity that reads those rings and the only entity that writes into any namespace's RX ring. A namespace has no mechanism to address another namespace's rings directly. The controller enforces addressing by construction, not by policy. Isolation between namespaces at the network layer is the same structural guarantee as isolation at the memory layer.

One NIC controller thread is assigned per streaming multiprocessor. Each controller owns the namespaces scheduled on its SM. Intra-SM traffic between two namespaces on the same SM passes through shared memory and never reaches global memory or the host. Inter-SM traffic between namespaces on different SMs passes through a global memory fabric between controllers. The host sees only traffic that is addressed to or from the outside world.

This architecture models real hardware accurately. A real machine has a CPU complex and peripheral controllers that are separate processors with their own firmware and their own access to the bus fabric. Chimera instantiates that structure in CUDA threads rather than in silicon. The NIC controller thread is a coprocessor. It has a defined interface to the namespace threads through the virtio descriptor rings and a defined interface to the host through mapped memory. Neither interface is the other's concern.

Networking is not implemented in the first version. The MMIO range for the virtio-net device is reserved in the memory map and the handler returns a bus error if any namespace touches it before the controller is implemented. The reservation ensures the memory map does not need to change when the controller is added.


## Divergence

Threads in a warp execute in lockstep. When threads in the same warp reach different branches, the hardware runs both sides with lanes masked off. For namespaces running independent programs on independent data, divergence is unavoidable.

Chimera does not attempt to eliminate divergence. The design target is throughput across thousands of independent namespaces, not instruction-level efficiency within a warp. Divergence within a warp is the cost of generality. It is offset by occupancy: when one warp stalls, the SM scheduler runs another. With enough live warps, the stalls disappear into the background.

For workloads where every namespace runs the same program over different input data, threads within a warp follow the same control paths and divergence is minimal. This is the workload Chimera is best suited for.


## Build Sequence

The implementation proceeds in stages, each verifiable before the next begins. Stages one through four are done and verified by verify.sh. Stage five is partly done and unmeasured. Stage six is not started.

Stage one implements the RV32I decode loop with the register file and private memory model, ignoring privileged mode entirely. A minimal bare-metal test binary assembled with GNU as and linked with a flat linker script runs under this stage and produces correct output. Isolation across N threads is verified by running N instances of the test binary with different input values and confirming N correct independent outputs.

Stage two adds M-mode CSR emulation, the CLINT timer, and interrupt delivery. A bare-metal program that installs a timer handler and responds to timer interrupts verifies this stage without involving Linux.

Stage three adds the NS16550 UART. A bare-metal program that prints through the UART and exits verifies the IO path before the kernel is involved.

Stage four boots NOMMU Linux. The kernel image is built with CONFIG_NOMMU, CONFIG_ARCH_RV32I, and the minimum driver set: the NS16550 UART driver and the CLINT timer driver. This is done. Linux 6.6.35 reaches an interactive BusyBox shell in one namespace, on the GPU and on the cpu build, and the two boots are byte identical.

Stage five scales to N namespaces. N private slices hold N independent machine states, N namespaces boot simultaneously and each produces a complete and identical boot log, which verify.sh checks. What remains is measurement: the wall clock of a boot at one namespace against the same boot at 64 and at 256, and the retired instructions per second implied by each. The claim this project rests on is that the second number is not much worse than the first, and it is not yet established.

Stage six implements the NIC controller threads and the virtio-net MMIO surface. One controller per SM. Intra-SM and inter-SM packet delivery is verified. A namespace that opens a TCP connection to the outside world and receives a response confirms the full network path.


## Hardware

The reference hardware is an RTX 3060 Ti: 38 streaming multiprocessors, 1536 threads per SM in flight simultaneously, 8GB GDDR6 VRAM. Maximum theoretical concurrency is 58368 threads. Memory, not threads, is the binding constraint: at the measured 16MB floor of guest RAM per namespace, 8GB holds roughly 450 to 480 slices, so the card runs out of VRAM long before it runs out of lanes. A single GPU thread is also considerably slower at branchy interpretation than a CPU core, so the one namespace case is expected to lose to the cpu build by a wide margin. The architectural claim is about aggregate throughput, and it stands or falls on measurement rather than on this paragraph.

# Licenses

Chimera itself, meaning [chimera.cu](./chimera.cu), [tools/mkdtb.c](tools/mkdtb.c), [bootstrap.sh](./bootstrap.sh), [run.sh](./run.sh), [verify.sh](./verify.sh), the tests and the documentation, is Copyright (C) 2026 Ivan Gaydardzhiev and is licensed GPL-3.0-only. The full text is in [COPYING](./COPYING).

Some files under [image/](image/) are not Chimera's work. They are compiled binaries of third party software published alongside the source so that a clone can boot without spending hours in [bootstrap.sh](./bootstrap.sh). They carry their own licenses and their own obligations, and those obligations fall on whoever redistributes this repository. [image/chimera.dtb](image/chimera.dtb) is not among them: it is generated by [tools/mkdtb.c](tools/mkdtb.c) from this repository and is Chimera's own work.

## Published binaries

[image/kernel.bin](image/kernel.bin) is an unmodified build of the Linux kernel version 6.6.35, licensed GPL-2.0-only, obtained from `https://cdn.kernel.org/pub/linux/kernel/v6.x/linux-6.6.35.tar.gz`. Its sha256 is `ac16a412766714b739f3446c64621ddde4945d512f8ccf27c1a14b68b9ee3326`.

[image/rootfs.cpio.gz](image/rootfs.cpio.gz) is an initramfs produced by Buildroot 2025.02.15, obtained from `https://buildroot.org/downloads/buildroot-2025.02.15.tar.xz`. Its sha256 is `357ea9726e7ad0fcf7d964f1acb8a44b824eb2bc55a0ae19d87c0e4b3461b72e`. It contains one executable, `bin/busybox`, which is BusyBox 1.37.0 licensed GPL-2.0-only, statically linked against uClibc-ng which is licensed LGPL-2.1-or-later. The remaining entries are symbolic links to that binary, two empty device nodes, and the two shell scripts `etc/inittab` and `etc/init.d/rcS`, which are Chimera's own work and are GPL-3.0-only along with the rest of the repository.

[image/initrd.bin](image/initrd.bin) is a byte-identical copy of [image/rootfs.cpio.gz](image/rootfs.cpio.gz), placed at the address the kernel expects by `run.sh pack`. Everything said here about the rootfs applies to it unchanged.

## Corresponding source

GPL-2.0-only section 3 requires that object code be accompanied by the complete corresponding source, which it defines as all the source for all modules the executable contains, plus any associated interface definition files, plus the scripts used to control compilation and installation.

The scripts used to control compilation are in this repository. [bootstrap.sh](./bootstrap.sh) pins the exact upstream versions and download URLs, writes the kernel configuration to `arch/riscv/configs/chimera_defconfig` and the BusyBox configuration to `chimera-busybox.config` as literal heredocs, and applies every Buildroot configuration change as an explicit edit. Running it reproduces both published binaries from upstream sources with no manual step, and reproduces them from unmodified upstream sources, because neither the kernel nor BusyBox is patched.

Neither binary is patched. Both are ordinary builds of unmodified upstream releases, so the corresponding source is the upstream release itself: `linux-6.6.35.tar.gz` for the kernel, and for the rootfs the BusyBox and uClibc-ng releases that Buildroot 2025.02.15 downloads during the build. The URLs and checksums are given above, [bootstrap.sh](./bootstrap.sh) pins the versions, and `make legal-info` in the Buildroot tree reproduces the exact set of source tarballs that went into the image along with a manifest of every component.

The source tarballs are not committed to this repository because the kernel release alone is more than an order of magnitude larger than everything else here and exceeds what the hosting platform accepts in a single file.

## Relinking

uClibc-ng is statically linked into `bin/busybox`. LGPL-2.1 section 6 requires that a recipient be able to relink the work against a modified version of the library. That is satisfied here because BusyBox is itself GPL-2.0-only and its complete source, its configuration and the toolchain that built it are all reproducible from [bootstrap.sh](./bootstrap.sh), so the entire binary can be rebuilt rather than merely relinked.

## Aggregation

The GPL-3.0-only emulator and the GPL-2.0-only guest binaries are separate works distributed on the same medium. Chimera does not link against the kernel or against BusyBox, does not derive from either, and does not incorporate any of their code. It executes them as data, the same way a processor does. This is mere aggregation, permitted by GPL-2.0-only section 2 and GPL-3.0-only section 5.

GPL-2.0-only and GPL-3.0-only are not compatible for combining into a single work. Kernel or BusyBox code must therefore never be copied into [chimera.cu](./chimera.cu) or any other Chimera source file. Emulating an interface is not copying an implementation, and the register layouts and instruction encodings Chimera implements come from the RISC-V specification and the NS16550 datasheet rather than from the Linux drivers for them.
