#!/bin/sh
#Copyright (C) 2026 Ivan Gaydardzhiev
#Licensed under the GPL-3.0-only

CHIMERA="${PWD}"
SRC="${CHIMERA}/src"
BUILD="${CHIMERA}/build"
SYSROOT="${CHIMERA}/sysroot"
KERNEL="${CHIMERA}/kernel"
ROOTFS="${CHIMERA}/rootfs"
IMAGE="${CHIMERA}/image"

TARGET="riscv32-unknown-linux-uclibc"
ARCH="riscv"
JOBS="-j$(grep -c '^processor' /proc/cpuinfo)"

BINUTILS="2.42"
GCC="13.3.0"
UCLIBC="1.0.47"
LINUX="6.6.35"
BUSYBOX="1.36.1"

BINUTILS_URL="https://ftp.gnu.org/gnu/binutils/binutils-${BINUTILS}.tar.gz"
GCC_URL="https://ftp.gnu.org/gnu/gcc/gcc-${GCC}/gcc-${GCC}.tar.gz"
UCLIBC_URL="https://downloads.uclibc-ng.org/releases/${UCLIBC}/uClibc-ng-${UCLIBC}.tar.gz"
LINUX_URL="https://cdn.kernel.org/pub/linux/kernel/v6.x/linux-${LINUX}.tar.gz"
BUSYBOX_URL="https://busybox.net/downloads/busybox-${BUSYBOX}.tar.bz2"

fusage() {
	printf "usage: %s <stage>\n" "${0}"
	printf "\n"
	printf "stages:\n"
	printf "	all | dirs | binutils | gcc-bootstrap | uclibc | gcc-final | linux | busybox | image\n"
	exit 1
}

fdirs() {
	rm -rf "${BUILD}"
	mkdir -p \
		"${SRC}" \
		"${BUILD}" \
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

fbinutils() {
	cd "${SRC}"
	wget "${BINUTILS_URL}"
	tar xf binutils-"${BINUTILS}".tar.gz
	rm binutils-"${BINUTILS}".tar.gz
	mkdir -p "${BUILD}/binutils"
	cd "${BUILD}/binutils"
	"${SRC}/binutils-${BINUTILS}/configure" \
		--prefix="${SYSROOT}" \
		--target="${TARGET}" \
		--with-sysroot="${SYSROOT}/${TARGET}" \
		--disable-nls \
		--disable-multilib \
		--disable-werror && \
	make "${JOBS}" && \
	make install
	rm -rf "${BUILD}/binutils"
	printf "binutils %s done\n" "${BINUTILS}"
}

fgcc_bootstrap() {
	cd "${SRC}"
	wget "${GCC_URL}"
	tar xf gcc-"${GCC}".tar.gz
	rm gcc-"${GCC}".tar.gz
	cd gcc-"${GCC}"
	./contrib/download_prerequisites
	mkdir -p "${BUILD}/gcc-bootstrap"
	cd "${BUILD}/gcc-bootstrap"
	"${SRC}/gcc-${GCC}/configure" \
		--prefix="${SYSROOT}" \
		--target="${TARGET}" \
		--with-arch=rv32im \
		--with-abi=ilp32 \
		--without-headers \
		--with-newlib \
		--with-gnu-as \
		--with-gnu-ld \
		--disable-nls \
		--disable-multilib \
		--disable-shared \
		--disable-threads \
		--disable-libssp \
		--disable-libgomp \
		--disable-libmudflap \
		--enable-languages=c && \
	make "${JOBS}" all-gcc && \
	make "${JOBS}" all-target-libgcc && \
	make install-gcc && \
	make install-target-libgcc
	rm -rf "${BUILD}/gcc-bootstrap"
	printf "gcc bootstrap %s done\n" "${GCC}"
}

fuclibc() {
	cd "${SRC}"
	wget "${UCLIBC_URL}"
	tar xf uClibc-ng-"${UCLIBC}".tar.gz
	rm uClibc-ng-"${UCLIBC}".tar.gz
	cd uClibc-ng-"${UCLIBC}"
	cat > .config << 'EOF'
CROSS_COMPILER_PREFIX="riscv32-unknown-linux-uclibc-"
KERNEL_HEADERS="/home/chimera/sysroot/riscv32-unknown-linux-uclibc/include"
TARGET_ARCH="riscv"
CONFIG_RV32=y
ARCH_LITTLE_ENDIAN=y
ARCH_WANTS_LITTLE_ENDIAN=y
HAVE_NO_MMU=y
UCLIBC_HAS_FLOATS=y
UCLIBC_HAS_FPU=n
DO_C99_MATH=y
UCLIBC_HAS_THREADS=y
LINUXTHREADS_OLD=y
UCLIBC_HAS_LOCALE=n
UCLIBC_HAS_WCHAR=n
UCLIBC_HAS_GLIBC_CUSTOM_PRINTF=n
UCLIBC_HAS_STDIO_FUTEXES=n
DEVEL_PREFIX="/usr"
RUNTIME_PREFIX="/"
EOF
	sed -i "s|/home/chimera|${CHIMERA}|g" .config
	make "${JOBS}" \
		CROSS="${SYSROOT}/bin/${TARGET}-" \
		PREFIX="${SYSROOT}/${TARGET}" \
		DEVEL_PREFIX="/usr" \
		RUNTIME_PREFIX="/" \
		install
	rm -rf "${SRC}/uClibc-ng-${UCLIBC}"
	printf "uclibc-ng %s done\n" "${UCLIBC}"
}

fgcc_final() {
	mkdir -p "${BUILD}/gcc-final"
	cd "${BUILD}/gcc-final"
	"${SRC}/gcc-${GCC}/configure" \
		--prefix="${SYSROOT}" \
		--target="${TARGET}" \
		--with-arch=rv32im \
		--with-abi=ilp32 \
		--with-sysroot="${SYSROOT}/${TARGET}" \
		--with-gnu-as \
		--with-gnu-ld \
		--disable-nls \
		--disable-multilib \
		--disable-libssp \
		--enable-threads \
		--enable-languages=c && \
	make "${JOBS}" && \
	make install
	rm -rf "${BUILD}/gcc-final"
	printf "gcc final %s done\n" "${GCC}"
}

flinux() {
	cd "${SRC}"
	wget "${LINUX_URL}"
	tar xf linux-"${LINUX}".tar.gz
	rm linux-"${LINUX}".tar.gz
	cp -r linux-"${LINUX}" "${KERNEL}/linux-${LINUX}"
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
	cat > "${ROOTFS}/etc/inittab" << 'EOF'
::sysinit:/etc/init.d/rcS
::respawn:/bin/sh
::ctrlaltdel:/sbin/reboot
::shutdown:/sbin/swapoff -a
::shutdown:/bin/umount -a -r
EOF
	mkdir -p "${ROOTFS}/etc/init.d"
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

ARG="${1}"

[ "${#}" -lt 1 ] && fusage

case "${ARG}" in
	dirs)
		fdirs
		;;
	binutils)
		fbinutils
		;;
	gcc-bootstrap)
		fgcc_bootstrap
		;;
	uclibc)
		fuclibc
		;;
	gcc-final)
		fgcc_final
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
	all)
		fdirs && \
		fbinutils && \
		fgcc_bootstrap && \
		fuclibc && \
		fgcc_final && \
		flinux && \
		fbusybox && \
		fimage
		;;
	*)
		printf "unsupported stage: %s\n" "${ARG}"
		fusage
		;;
esac
