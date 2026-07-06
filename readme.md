# Chimera

Chimera is a massively parallel RISC-V emulator running on Nvidia GPU hardware. It boots one NOMMU RV32I Linux kernel image into shared read-only device memory and multiplexes thousands of isolated process namespaces on top of it, one per CUDA thread. Each namespace has its own register file, its own private writable memory region, its own file descriptors, and its own output buffer. The kernel and all read-only library and filesystem data are shared across every namespace simultaneously. A write to the shared region faults the offending namespace and terminates it. The others continue.

The result is thousands of structurally isolated Linux process environments on one GPU card, each believing it owns the machine, none of them able to affect any other, all running simultaneously in the time it takes to run one.


## The Problem

Linux containers on a CPU share a kernel but isolate process state through namespace and cgroup machinery built into the kernel itself. The isolation is a policy enforced by software. It works, but each container still requires its own kernel scheduler, its own memory allocator context, its own device driver surface. The overhead per container is real and it accumulates.

Running thousands of fully isolated environments on one machine today means either thousands of containers with nontrivial per-container overhead, or thousands of virtual machines with even higher overhead. Neither scales to the thread counts a modern GPU makes available.

Chimera approaches the problem differently. The isolation boundary is the emulator, not the kernel. The kernel inside does not know it is being multiplied. It sees one machine. The emulator provides thousands of private address spaces on top of one shared kernel image, and the GPU's own hardware scheduler keeps the execution units busy while individual namespaces stall on memory or block on IO.


## Memory Layout

VRAM is divided into two regions before the kernel launches.

The shared region holds the kernel image, the root filesystem, and all read-only library data. It is written once by the host before the kernel launches and never modified again. Every thread reads from it freely. A 64MB shared region is sufficient for a minimal NOMMU Linux with busybox and uclibc.

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


## License

This project is provided under the [GPL3 License](./COPYING) Copyright (C) 2026 Ivan Gaydardzhiev
