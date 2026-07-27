#!/bin/sh
#Copyright (C) 2026 Ivan Gaydardzhiev
#Licensed under the GPL-3.0-only

set -eu

CHIMERA="${PWD}"
IMAGE="${CHIMERA}/image"
KERNEL="${CHIMERA}/kernel"
TOOLS="${CHIMERA}/tools"
LINUX="6.6.35"

KERNEL_IMAGE="${KERNEL}/linux-${LINUX}/arch/riscv/boot/Image"
ROOTFS_CPIO="${IMAGE}/rootfs.cpio.gz"
KERNEL_BIN="${IMAGE}/kernel.bin"
INITRD_BIN="${IMAGE}/initrd.bin"
DTB_BIN="${IMAGE}/chimera.dtb"
COMBINED_BIN="${IMAGE}/boot.bin"

KERNEL_LOAD=0x80000000
RAM_SIZE=2000000
TIMEBASE=10000000
INITRD_LOAD=0x80300000
DTB_LOAD=0x80400000

CMDLINE="earlycon=uart8250,mmio,0x10000000 console=ttyS0,115200 rdinit=/sbin/init"

fusage() {
	printf "usage: %s <stage> [args]\n" "${0}"
	printf "\n"
	printf "stages:\n"
	printf "	all | mkdtb | pack | boot <N> | cpuboot\n"
	exit 1
}

fmkdtb() {
	cc -O2 -o "${TOOLS}/mkdtb" "${TOOLS}/mkdtb.c"
	initrd_start="$(printf '%x' ${INITRD_LOAD})"
	initrd_size="$(wc -c < "${ROOTFS_CPIO}" | tr -d ' ')"
	initrd_end="$(printf '%x' $((INITRD_LOAD + initrd_size)))"
	"${TOOLS}/mkdtb" \
		"${initrd_start}" \
		"${initrd_end}" \
		"${CMDLINE}" \
		"${DTB_BIN}" \
		"${RAM_SIZE}" \
		"${TIMEBASE}"
	printf "dtb ready: %s\n" "${DTB_BIN}"
}

fpack() {
	[ -f "${DTB_BIN}" ] || {
		printf "dtb not found, run mkdtb first\n" >&2
		exit 1
	}
	if [ -f "${KERNEL_IMAGE}" ]; then
		cp "${KERNEL_IMAGE}" "${KERNEL_BIN}"
	elif [ ! -f "${KERNEL_BIN}" ]; then
		printf "kernel image not found: %s\n" "${KERNEL_IMAGE}" >&2
		printf "run bootstrap.sh, or publish image/kernel.bin\n" >&2
		exit 1
	fi
	if [ -f "${ROOTFS_CPIO}" ]; then
		cp "${ROOTFS_CPIO}" "${INITRD_BIN}"
	elif [ ! -f "${INITRD_BIN}" ]; then
		printf "rootfs not found: %s\n" "${ROOTFS_CPIO}" >&2
		printf "run bootstrap.sh, or publish image/rootfs.cpio.gz\n" >&2
		exit 1
	fi
	kernel_size="$(wc -c < "${KERNEL_BIN}" | tr -d ' ')"
	initrd_size="$(wc -c < "${INITRD_BIN}" | tr -d ' ')"
	dtb_size="$(wc -c < "${DTB_BIN}" | tr -d ' ')"
	printf "kernel:  %d bytes at 0x%08x\n" "${kernel_size}" "${KERNEL_LOAD}"
	printf "initrd:  %d bytes at 0x%08x\n" "${initrd_size}" "${INITRD_LOAD}"
	printf "dtb:     %d bytes at 0x%08x\n" "${dtb_size}" "${DTB_LOAD}"
	printf "pack ready\n"
}

fboot() {
	N="${1:-1}"
	BINARY="${2:-chimera}"
	[ -f "${KERNEL_BIN}" ] || {
		printf "kernel.bin not found, run pack first\n" >&2
		exit 1
	}
	[ -f "${INITRD_BIN}" ] || {
		printf "initrd.bin not found, run pack first\n" >&2
		exit 1
	}
	[ -f "${DTB_BIN}" ] || {
		printf "chimera.dtb not found, run mkdtb first\n" >&2
		exit 1
	}
	printf "booting %s namespaces\n" "${N}"
	"${CHIMERA}/${BINARY}" \
		"${KERNEL_BIN}" \
		"${INITRD_BIN}" \
		"${DTB_BIN}" \
		"${N}"
}

ARG="${1:-}"

[ -z "${ARG}" ] && fusage

case "${ARG}" in
	mkdtb)
		fmkdtb
		;;
	pack)
		fpack
		;;
	boot)
		fboot "${2:-1}" chimera
		;;
	cpuboot)
		fboot 1 chimera-cpu
		;;
	all)
		fmkdtb && fpack && fboot "${2:-1}" chimera
		;;
	*)
		printf "unsupported stage: %s\n" "${ARG}"
		fusage
		;;
esac
