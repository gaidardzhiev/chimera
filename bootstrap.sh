#!/bin/sh
#Copyright (C) 2026 Ivan Gaydardzhiev
#Licensed under the GPL-3.0-only

set -eu

CHIMERA="${PWD}"
SRC="${CHIMERA}/src"
SYSROOT="${CHIMERA}/sysroot"
SYSROOT_LINUX="${CHIMERA}/sysroot-linux"
BUILDROOT_OUTPUT="${CHIMERA}/buildroot-nommu"
SYSROOT_NOMMU="${BUILDROOT_OUTPUT}/host"
KERNEL="${CHIMERA}/kernel"
ROOTFS="${CHIMERA}/rootfs"
IMAGE="${CHIMERA}/image"
TARGET="riscv32-unknown-elf"
TARGET_LINUX="riscv32-unknown-linux-gnu"
TARGET_NOMMU="riscv32-buildroot-linux-uclibc"
ARCH="riscv"
JOBS="-j$(grep -c '^processor' /proc/cpuinfo)"
TOOLCHAIN_REPO="https://github.com/riscv-collab/riscv-gnu-toolchain"
BUILDROOT="2025.02.15"
BUILDROOT_URL="https://buildroot.org/downloads/buildroot-${BUILDROOT}.tar.xz"
LINUX="6.6.35"
BUSYBOX="1.36.1"
LINUX_URL="https://cdn.kernel.org/pub/linux/kernel/v6.x/linux-${LINUX}.tar.gz"
BUSYBOX_URL="https://busybox.net/downloads/busybox-${BUSYBOX}.tar.bz2"

export PATH="${SYSROOT}/bin:${SYSROOT_LINUX}/bin:${PATH}"

fusage() {
	printf "usage: %s <stage>\n" "${0}"
	printf "\n"
	printf "stages:\n"
	printf "\tall | dirs | toolchain | toolchain-linux | toolchain-nommu | linux | busybox | image | symlink\n"
	exit 1
}

fdirs() {
	mkdir -p \
		"${SRC}" \
		"${SYSROOT}" \
		"${SYSROOT_LINUX}" \
		"${BUILDROOT_OUTPUT}" \
		"${KERNEL}" \
		"${ROOTFS}" \
		"${ROOTFS}/bin" \
		"${ROOTFS}/sbin" \
		"${ROOTFS}/etc" \
		"${ROOTFS}/proc" \
		"${ROOTFS}/sys" \
		"${ROOTFS}/dev" \
		"${ROOTFS}/tmp" \
		"${IMAGE}"
	printf "dirs ready: %s\n" "${CHIMERA}"
}

ftoolchain() {
	cd "${SRC}"
	[ -d riscv-gnu-toolchain ] || git clone "${TOOLCHAIN_REPO}" riscv-gnu-toolchain
	cd riscv-gnu-toolchain
	./configure \
		--prefix="${SYSROOT}" \
		--with-arch=rv32ima_zicsr_zifencei \
		--with-abi=ilp32 \
		--enable-languages=c \
		--disable-gdb
	make "${JOBS}"
	printf "toolchain done\n"
	printf "add to your shell rc:\n"
	printf "export PATH=\"%s/bin:\${PATH}\"\n" "${SYSROOT}"
}

ftoolchain_linux() {
	cd "${SRC}/riscv-gnu-toolchain"
	./configure \
		--prefix="${SYSROOT_LINUX}" \
		--with-arch=rv32ima \
		--with-abi=ilp32 \
		--enable-languages=c \
		--disable-gdb
	make "${JOBS}" linux
	printf "linux toolchain done\n"
	printf "add to your shell rc:\n"
	printf "export PATH=\"%s/bin:\${PATH}\"\n" "${SYSROOT_LINUX}"
}

ftoolchain_nommu() {
	cd "${SRC}"
	[ -f buildroot-"${BUILDROOT}".tar.xz ] || wget "${BUILDROOT_URL}"
	[ -d buildroot-"${BUILDROOT}" ] || tar xJf buildroot-"${BUILDROOT}".tar.xz
	cd buildroot-"${BUILDROOT}"
	make \
		O="${BUILDROOT_OUTPUT}" \
		qemu_riscv32_nommu_virt_defconfig
	make "${JOBS}" \
		O="${BUILDROOT_OUTPUT}" \
		toolchain
	[ -x "${SYSROOT_NOMMU}/bin/${TARGET_NOMMU}-gcc" ]
	[ -x "${SYSROOT_NOMMU}/bin/elf2flt" ]
	cat > "${BUILDROOT_OUTPUT}/chimera-nommu-test.c" << 'EOF'
int main(void)
{
	return 0;
}
EOF
	"${SYSROOT_NOMMU}/bin/${TARGET_NOMMU}-gcc" \
		-Os \
		-static \
		-o "${BUILDROOT_OUTPUT}/chimera-nommu-test" \
		"${BUILDROOT_OUTPUT}/chimera-nommu-test.c"
	magic="$(od -An -tx1 -N4 "${BUILDROOT_OUTPUT}/chimera-nommu-test" | tr -d ' \n')"
	[ "${magic}" = "62464c54" ] || {
		printf "nommu toolchain produced invalid binary magic: %s\n" "${magic}" >&2
		exit 1
	}
	printf "nommu toolchain done\n"
	printf "compiler: %s/bin/%s-gcc\n" "${SYSROOT_NOMMU}" "${TARGET_NOMMU}"
	printf "binary format: bFLT\n"
}

flinux() {
	cd "${SRC}"
	wget "${LINUX_URL}"
	tar xf linux-"${LINUX}".tar.gz
	rm linux-"${LINUX}".tar.gz
	cp -r linux-"${LINUX}" "${KERNEL}/linux-${LINUX}"
	rm -rf linux-"${LINUX}"
	cd "${KERNEL}/linux-${LINUX}"
	cat > arch/riscv/configs/chimera_defconfig << 'EOF'
CONFIG_RISCV=y
CONFIG_32BIT=y
CONFIG_ARCH_RV32I=y
CONFIG_NOMMU=y
CONFIG_HZ_100=y
CONFIG_EMBEDDED=y
CONFIG_KERNEL_XZ=y
CONFIG_PRINTK=y
CONFIG_BUG=y
CONFIG_BASE_FULL=n
CONFIG_FUTEX=y
CONFIG_EPOLL=y
CONFIG_SIGNALFD=y
CONFIG_TIMERFD=y
CONFIG_SHMEM=n
CONFIG_AIO=n
CONFIG_MEMFD_CREATE=n
CONFIG_NET=y
CONFIG_INET=y
CONFIG_IP_MULTICAST=n
CONFIG_PACKET=y
CONFIG_UNIX=y
CONFIG_VIRTIO_NET=y
CONFIG_VIRTIO_MMIO=y
CONFIG_SERIAL_8250=y
CONFIG_SERIAL_8250_CONSOLE=y
CONFIG_SERIAL_OF_PLATFORM=y
CONFIG_CLINT_TIMER=y
CONFIG_RISCV_SBI=n
CONFIG_BINFMT_ELF=y
CONFIG_BINFMT_SCRIPT=y
CONFIG_RAMFS=y
CONFIG_TMPFS=n
CONFIG_PROC_FS=y
CONFIG_SYSFS=y
CONFIG_DEVTMPFS=y
CONFIG_TTY=y
CONFIG_VT=n
CONFIG_UNIX98_PTYS=y
CONFIG_MODULES=n
CONFIG_BLOCK=n
CONFIG_INITRAMFS_SOURCE=""
CONFIG_DEFAULT_HOSTNAME="chimera"
EOF
	make \
		ARCH="${ARCH}" \
		CROSS_COMPILE="${SYSROOT_LINUX}/bin/${TARGET_LINUX}-" \
		chimera_defconfig && \
	make "${JOBS}" \
		ARCH="${ARCH}" \
		CROSS_COMPILE="${SYSROOT_LINUX}/bin/${TARGET_LINUX}-"
	cp arch/riscv/boot/Image "${IMAGE}/kernel.bin"
	printf "linux %s done\n" "${LINUX}"
}

fbusybox() {
	cd "${SRC}"
	wget "${BUSYBOX_URL}"
	tar xjf busybox-"${BUSYBOX}".tar.bz2
	rm busybox-"${BUSYBOX}".tar.bz2
	cd busybox-"${BUSYBOX}"
	make \
		CROSS_COMPILE="${SYSROOT_NOMMU}/bin/${TARGET_NOMMU}-" \
		defconfig
	sed -i \
		's/# CONFIG_STATIC is not set/CONFIG_STATIC=y/' \
		.config
	make "${JOBS}" \
		CROSS_COMPILE="${SYSROOT_NOMMU}/bin/${TARGET_NOMMU}-" && \
	make \
		CROSS_COMPILE="${SYSROOT_NOMMU}/bin/${TARGET_NOMMU}-" \
		CONFIG_PREFIX="${ROOTFS}" \
		install
	printf "busybox %s done\n" "${BUSYBOX}"
}

fimage() {
	mkdir -p "${ROOTFS}/etc/init.d"
	cat > "${ROOTFS}/etc/inittab" << 'EOF'
::sysinit:/etc/init.d/rcS
::respawn:/bin/sh
::ctrlaltdel:/sbin/reboot
::shutdown:/sbin/swapoff -a
::shutdown:/bin/umount -a -r
EOF
	cat > "${ROOTFS}/etc/init.d/rcS" << 'EOF'
#!/bin/sh
mount -t proc proc /proc
mount -t sysfs sysfs /sys
mount -t devtmpfs devtmpfs /dev
hostname chimera
EOF
	chmod +x "${ROOTFS}/etc/init.d/rcS"
	cd "${ROOTFS}"
	find . | cpio -H newc -o | gzip > "${IMAGE}/rootfs.cpio.gz"
	printf "image ready: %s\n" "${IMAGE}"
	ls -lh "${IMAGE}"
}

fsymlink() {
	ln -sf "${SYSROOT}/bin/${TARGET}-gcc" /usr/local/bin/riscv32-gcc
	ln -sf "${SYSROOT}/bin/${TARGET}-as" /usr/local/bin/riscv32-as
	ln -sf "${SYSROOT}/bin/${TARGET}-ld" /usr/local/bin/riscv32-ld
	ln -sf "${SYSROOT}/bin/${TARGET}-objdump" /usr/local/bin/riscv32-objdump
	ln -sf "${SYSROOT}/bin/${TARGET}-objcopy" /usr/local/bin/riscv32-objcopy
	ln -sf "${SYSROOT}/bin/${TARGET}-strip" /usr/local/bin/riscv32-strip
	ln -sf "${SYSROOT}/bin/${TARGET}-readelf" /usr/local/bin/riscv32-readelf
	printf "symlinks ready in /usr/local/bin\n"
}

ARG="${1:-}"

[ -z "${ARG}" ] && fusage

case "${ARG}" in
	dirs)
		fdirs
		;;
	toolchain)
		ftoolchain
		;;
	toolchain-linux)
		ftoolchain_linux
		;;
	toolchain-nommu)
		ftoolchain_nommu
		;;
	linux)
		flinux
		;;
	busybox)
		fbusybox
		;;
	image)
		fimage
		;;
	symlink)
		fsymlink
		;;
	all)
		fdirs && \
		ftoolchain && \
		ftoolchain_linux && \
		ftoolchain_nommu && \
		flinux && \
		fbusybox && \
		fimage && \
		fsymlink
		;;
	*)
		printf "unsupported stage: %s\n" "${ARG}"
		fusage
		;;
esac
