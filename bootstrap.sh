#!/bin/sh
#Copyright (C) 2026 Ivan Gaydardzhiev
#Licensed under the GPL-3.0-only

CHIMERA="${PWD}"
SRC="${CHIMERA}/src"
SYSROOT="${CHIMERA}/sysroot"
KERNEL="${CHIMERA}/kernel"
ROOTFS="${CHIMERA}/rootfs"
IMAGE="${CHIMERA}/image"
TARGET="riscv32-unknown-linux-gnu"
ARCH="riscv"
JOBS="-j$(grep -c '^processor' /proc/cpuinfo)"
TOOLCHAIN_REPO="https://github.com/riscv-collab/riscv-gnu-toolchain"
LINUX="6.6.35"
BUSYBOX="1.36.1"
LINUX_URL="https://cdn.kernel.org/pub/linux/kernel/v6.x/linux-${LINUX}.tar.gz"
BUSYBOX_URL="https://busybox.net/downloads/busybox-${BUSYBOX}.tar.bz2"

fusage() {
	printf "usage: %s <stage>\n" "${0}"
	printf "\n"
	printf "stages:\n"
	printf "	all | dirs | toolchain | linux | busybox | image | symlink\n"
	exit 1
}

fdirs() {
	mkdir -p \
		"${SRC}" \
		"${SYSROOT}" \
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
	git clone "${TOOLCHAIN_REPO}" riscv-gnu-toolchain
	cd riscv-gnu-toolchain
	./configure \
		--prefix="${SYSROOT}" \
		--with-arch=rv32im \
		--with-abi=ilp32 && \
	make "${JOBS}" linux
	printf "toolchain done\n"
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
		CROSS_COMPILE="${SYSROOT}/bin/${TARGET}-" \
		chimera_defconfig && \
	make "${JOBS}" \
		ARCH="${ARCH}" \
		CROSS_COMPILE="${SYSROOT}/bin/${TARGET}-"
	cp arch/riscv/boot/Image "${IMAGE}/kernel.bin"
	printf "linux %s done\n" "${LINUX}"
}

fbusybox() {
	cd "${SRC}"
	wget "${BUSYBOX_URL}"
	bzip2 -d busybox-"${BUSYBOX}".tar.bz2
	tar xf busybox-"${BUSYBOX}".tar
	rm busybox-"${BUSYBOX}".tar
	cd busybox-"${BUSYBOX}"
	make \
		CROSS_COMPILE="${SYSROOT}/bin/${TARGET}-" \
		defconfig
	sed -i \
		's/# CONFIG_STATIC is not set/CONFIG_STATIC=y/' \
		.config
	make "${JOBS}" \
		CROSS_COMPILE="${SYSROOT}/bin/${TARGET}-" && \
	make \
		CROSS_COMPILE="${SYSROOT}/bin/${TARGET}-" \
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

ARG="${1}"

[ "${#}" -lt 1 ] && fusage

case "${ARG}" in
	dirs)
		fdirs
		;;
	toolchain)
		ftoolchain
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
