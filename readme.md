# Chimera

Chimera is a massively parallel RISC-V emulator running on Nvidia GPU hardware. It boots one NOMMU RV32I Linux kernel image into shared read-only device memory and multiplexes thousands of isolated process namespaces on top of it, one per CUDA thread. Each namespace has its own register file, its own private writable memory region, its own file descriptors, and its own output buffer. The kernel and all read-only library and filesystem data are shared across every namespace simultaneously. A write to the shared region faults the offending namespace and terminates it. The others continue.

The result is thousands of structurally isolated Linux process environments on one GPU card, each believing it owns the machine, none of them able to affect any other, all running simultaneously in the time it takes to run one.


## The Problem

Linux containers on a CPU share a kernel but isolate process state through namespace and cgroup machinery built into the kernel itself. The isolation is a policy enforced by software. It works, but each container still requires its own kernel scheduler, its own memory allocator context, its own device driver surface. The overhead per container is real and it accumulates.

Running thousands of fully isolated environments on one machine today means either thousands of containers with nontrivial per-container overhead, or thousands of virtual machines with even higher overhead. Neither scales to the thread counts a modern GPU makes available.

Chimera approaches the problem differently. The isolation boundary is the emulator, not the kernel. The kernel inside does not know it is being multiplied. It sees one machine. The emulator provides thousands of private address spaces on top of one shared kernel image, and the GPU's own hardware scheduler keeps the execution units busy while individual namespaces stall on memory or block on IO.


## Memory Layout

VRAM is divided into two regions before the kernel launches.

The shared region holds the kernel text section, the root filesystem, and all read-only library data. The kernel text is the executable code only. The kernel data, bss, and init sections are writable and live in each namespace's private slice alongside the process memory. A Linux kernel writes into its own data sections during initialization, patches alternatives, and initializes global structures. None of that touches the text section, which is genuinely read-only after the image is built. The shared region is written once by the host before the kernel launches and never modified again. Every thread reads from it freely. A 64MB shared region is sufficient for a minimal NOMMU Linux with busybox and uclibc.

The private region is partitioned into per-thread slices. Each slice holds the complete mutable state of one namespace: the register file, the CSR set, the stack, the heap arena, the file descriptor table, and the output buffer. The slice size is a compile-time constant. On an RTX 3060 Ti with 8GB VRAM, after reserving the shared region, approximately 7.9GB remains for private slices. At 2MB per slice, nearly 4000 namespaces fit. At 1MB, close to 8000.

    VRAM:
    [ shared RO: kernel, rootfs, libs       ~64MB          ]
    [ private RW: namespace 0               slice_size     ]
    [ private RW: namespace 1               slice_size     ]
    [ private RW: namespace 2               slice_size     ]
    [ NIC controller 0                      fixed region   ]
    [ NIC controller 1..M                   fixed region   ]
    ...

Each namespace thread computes its private base as:

    private = private_pool + thread_id * SLICE_SIZE

Reads from the shared region require no synchronization. Writes to it are detected by range check in the memory access path of the emulator and fault the namespace immediately.


## Emulated Hardware

Chimera emulates a minimal RV32I machine sufficient to boot NOMMU Linux and run processes under it. The emulated hardware surface is small by design.

The CPU implements the RV32I base integer instruction set. All 47 instructions are implemented. The register file is 32 32-bit registers with x0 hardwired to zero. The M extension (integer multiply and divide) is included because the Linux kernel and uclibc require it. No other extensions are implemented in the first version.

Privileged mode covers M-mode only, which is sufficient for NOMMU Linux acting as its own machine-mode runtime. The implemented CSRs are mstatus, mie, mip, mepc, mcause, mtvec, and mscratch. The satp register exists but is ignored: there is no MMU and no address translation. Virtual addresses are physical addresses.

The CLINT provides mtime and mtimecmp as MMIO registers. The emulator advances mtime by a fixed quantum at the top of each fetch loop iteration. When mtime exceeds mtimecmp and the timer interrupt is enabled in mie and mstatus, the emulator delivers the interrupt before fetching the next instruction. This is the mechanism by which the Linux scheduler receives its timer ticks.

The UART is an NS16550-compatible device implemented as four MMIO registers. Writes to the transmit register append to the namespace's output buffer. Reads from the receive register consume bytes from the namespace's input buffer. The kernel uses this for console output and for communication with the process running inside the namespace.

No other devices are emulated beyond what the networking section describes. No PCI bus, no block device, no interrupt controller beyond the CLINT. The hardware surface is the minimum that NOMMU Linux requires to boot and run a process.


## Isolation

Isolation between namespaces is structural. Each namespace has its own private memory slice. There is no shared mutable state between namespaces unless explicitly arranged by the host before launch. A namespace cannot address another namespace's private memory because its address space does not contain it.

The shared region is the only memory visible to all namespaces simultaneously, and it is read-only after launch. A write to it is a fault. The faulting namespace is marked done and its output is discarded. No signal is sent to other namespaces. They do not observe the fault.

A runaway allocation that exhausts the private heap arena, a stack overflow, a division by zero, an infinite loop: none of these affect any namespace but the one in which they occur. The others finish and their output is collected normally.

This isolation is stronger than what Linux containers provide on a CPU. Containers share a kernel. A kernel bug or a privilege escalation that reaches the kernel affects all containers on the host. Under Chimera the kernel is a read-only artifact. The emulator is the isolation boundary. A misbehaving namespace cannot affect the emulator itself because the emulator runs in CUDA device code outside the address space the namespace can reach.


## IO

Input is supplied by the host before the kernel launches. Each namespace receives a pointer to its input slice in the private region. The UART receive path reads from this slice. No synchronization is needed because input is written before launch and read sequentially by one thread.

Output is accumulated in the namespace's output buffer through the UART transmit path. When a namespace exits cleanly, its output buffer is collected by the host after all threads finish. Collection is ordered by namespace index and is deterministic regardless of how the GPU hardware scheduled the warps.

The output buffer has a fixed maximum size defined at compile time. A namespace that produces more output than the buffer holds receives a transmit failure from the UART. The program inside the namespace observes this as a write error. The behavior at that point is the program's problem.

Streaming output during kernel execution, rather than batch collection at the end, is not supported in the first version. It requires coordination between device and host memory that adds complexity without benefit for the workload Chimera targets: batch execution of one program over many inputs, where collection at the end is the natural model.


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

Chimera is not yet implemented. This document describes the design.

The implementation proceeds in stages, each verifiable before the next begins.

Stage one implements the RV32I decode loop with the register file and private memory model, ignoring privileged mode entirely. A minimal bare-metal test binary assembled with GNU as and linked with a flat linker script runs under this stage and produces correct output. Isolation across N threads is verified by running N instances of the test binary with different input values and confirming N correct independent outputs.

Stage two adds M-mode CSR emulation, the CLINT timer, and interrupt delivery. A bare-metal program that installs a timer handler and responds to timer interrupts verifies this stage without involving Linux.

Stage three adds the NS16550 UART. A bare-metal program that prints through the UART and exits verifies the IO path before the kernel is involved.

Stage four boots NOMMU Linux. The kernel image is built with CONFIG_NOMMU, CONFIG_ARCH_RV32I, and the minimum driver set: the NS16550 UART driver and the CLINT timer driver. A successful boot to a busybox shell prompt in one namespace verifies the emulation layer is correct.

Stage five scales to N namespaces. The shared region holds one kernel image. N private slices hold N independent process states. N namespaces boot simultaneously and each produces correct output. Divergence and occupancy are measured against the single-namespace baseline.

Stage six implements the NIC controller threads and the virtio-net MMIO surface. One controller per SM. Intra-SM and inter-SM packet delivery is verified. A namespace that opens a TCP connection to the outside world and receives a response confirms the full network path.


## Hardware

The reference hardware is an RTX 3060 Ti: 38 streaming multiprocessors, 1536 threads per SM in flight simultaneously, 8GB GDDR6 VRAM. Maximum theoretical concurrency is 58368 threads. In practice, register pressure from the emulator state per thread will reduce this. Actual concurrent namespace count is a function of SLICE_SIZE, register spill, and the shared region size, and will be measured rather than predicted.

# Licenses

Chimera itself, meaning `chimera.cu`, `tools/mkdtb.c`, `bootstrap.sh`, `run.sh`, `verify.sh`, the tests and the documentation, is Copyright (C) 2026 Ivan Gaydardzhiev and is licensed GPL-3.0-only. The full text is in [COPYING](./COPYING).

Two files under `image/` are not Chimera's work. They are compiled binaries of third party software published alongside the source so that a clone can boot without spending hours in `bootstrap.sh`. They carry their own licenses and their own obligations, and those obligations fall on whoever redistributes this repository.

## Published binaries

`image/kernel.bin` is an unmodified build of the Linux kernel version 6.6.35, licensed GPL-2.0-only, obtained from `https://cdn.kernel.org/pub/linux/kernel/v6.x/linux-6.6.35.tar.gz`. Its sha256 is `ac16a412766714b739f3446c64621ddde4945d512f8ccf27c1a14b68b9ee3326`.

`image/rootfs.cpio.gz` is an initramfs produced by Buildroot 2025.02.15, obtained from `https://buildroot.org/downloads/buildroot-2025.02.15.tar.xz`. Its sha256 is `357ea9726e7ad0fcf7d964f1acb8a44b824eb2bc55a0ae19d87c0e4b3461b72e`. It contains one executable, `bin/busybox`, which is BusyBox 1.37.0 licensed GPL-2.0-only, statically linked against uClibc-ng which is licensed LGPL-2.1-or-later. The remaining entries are symbolic links to that binary, two empty device nodes, and the two shell scripts `etc/inittab` and `etc/init.d/rcS`, which are Chimera's own work and are GPL-3.0-only along with the rest of the repository.

Note that the BusyBox in the published rootfs is 1.37.0, the version Buildroot 2025.02.15 supplies. It is not the 1.36.1 named by the abandoned manual build path described in hacking.md.

## Corresponding source

GPL-2.0-only section 3 requires that object code be accompanied by the complete corresponding source, which it defines as all the source for all modules the executable contains, plus any associated interface definition files, plus the scripts used to control compilation and installation.

The scripts used to control compilation are in this repository. [bootstrap.sh](./bootstrap.sh) pins the exact upstream versions and download URLs, writes the kernel configuration to `arch/riscv/configs/chimera_defconfig` and the BusyBox configuration to `chimera-busybox.config` as literal heredocs, and applies every Buildroot configuration change as an explicit edit. Running it reproduces both published binaries from upstream sources with no manual step, and reproduces them from unmodified upstream sources, because neither the kernel nor BusyBox is patched.

The upstream sources are distributed with the binaries rather than referenced. Every release that carries `image/kernel.bin` and `image/rootfs.cpio.gz` also carries the corresponding source as attached assets, unmodified and with their upstream checksums, so that the source travels with the object code it corresponds to. They are attached to the release rather than committed to the tree only because their combined size is two orders of magnitude larger than the rest of the repository.

For `image/kernel.bin` that is `linux-6.6.35.tar.gz`. For `image/rootfs.cpio.gz` it is the output of `make legal-info` in the Buildroot tree, which collects the source tarball of every package that went into the image, including BusyBox and uClibc-ng, together with the license text of each and a manifest naming the version and license of every component. Buildroot downloads those tarballs during the build rather than carrying them, so the Buildroot release tarball alone is the build system and not the corresponding source of what it produced.

## Relinking

uClibc-ng is statically linked into `bin/busybox`. LGPL-2.1 section 6 requires that a recipient be able to relink the work against a modified version of the library. That is satisfied here because BusyBox is itself GPL-2.0-only and its complete source, its configuration and the toolchain that built it are all reproducible from `bootstrap.sh`, so the entire binary can be rebuilt rather than merely relinked.

## Aggregation

The GPL-3.0-only emulator and the GPL-2.0-only guest binaries are separate works distributed on the same medium. Chimera does not link against the kernel or against BusyBox, does not derive from either, and does not incorporate any of their code. It executes them as data, the same way a processor does. This is mere aggregation, permitted by GPL-2.0-only section 2 and GPL-3.0-only section 5.

GPL-2.0-only and GPL-3.0-only are not compatible for combining into a single work. Kernel or BusyBox code must therefore never be copied into `chimera.cu` or any other Chimera source file. Emulating an interface is not copying an implementation, and the register layouts and instruction encodings Chimera implements come from the RISC-V specification and the NS16550 datasheet rather than from the Linux drivers for them.
