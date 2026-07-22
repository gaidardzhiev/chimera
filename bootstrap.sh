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
	printf "\tall | dirs | toolchain | toolchain-linux | toolchain-nommu | linux | busybox | image | qemu\n"
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
	sed -i \
		-e '/^BR2_RISCV_ISA_RVF=/d' \
		-e '/^# BR2_RISCV_ISA_RVF is not set/d' \
		-e '/^BR2_RISCV_ISA_RVD=/d' \
		-e '/^# BR2_RISCV_ISA_RVD is not set/d' \
		-e '/^BR2_RISCV_ABI_ILP32=/d' \
		-e '/^# BR2_RISCV_ABI_ILP32 is not set/d' \
		-e '/^BR2_RISCV_ABI_ILP32D=/d' \
		-e '/^# BR2_RISCV_ABI_ILP32D is not set/d' \
		"${BUILDROOT_OUTPUT}/.config"
	cat >> "${BUILDROOT_OUTPUT}/.config" << 'EOF'
# BR2_RISCV_ISA_RVF is not set
# BR2_RISCV_ISA_RVD is not set
BR2_RISCV_ABI_ILP32=y
# BR2_RISCV_ABI_ILP32D is not set
EOF
	make \
		O="${BUILDROOT_OUTPUT}" \
		olddefconfig
	make "${JOBS}" \
		O="${BUILDROOT_OUTPUT}" \
		toolchain
	[ -x "${SYSROOT_NOMMU}/bin/${TARGET_NOMMU}-gcc" ]
	[ -x "${SYSROOT_NOMMU}/bin/${TARGET_NOMMU}-elf2flt" ]
	cat > "${BUILDROOT_OUTPUT}/chimera-nommu-test.c" << 'EOF'
int
main(void)
{
	return 0;
}
EOF
	"${SYSROOT_NOMMU}/bin/${TARGET_NOMMU}-gcc" \
		-Os \
		-static \
		-Wl,-elf2flt=-r \
		-o "${BUILDROOT_OUTPUT}/chimera-nommu-test" \
		"${BUILDROOT_OUTPUT}/chimera-nommu-test.c"
	magic="$(od -An -tx1 -N4 \
		"${BUILDROOT_OUTPUT}/chimera-nommu-test" |
		tr -d ' \n')"
	[ "${magic}" = "62464c54" ] || {
		printf "nommu toolchain produced invalid binary magic: %s\n" \
			"${magic}" >&2
		exit 1
	}
	printf "nommu toolchain done\n"
	printf "compiler: %s/bin/%s-gcc\n" \
		"${SYSROOT_NOMMU}" \
		"${TARGET_NOMMU}"
	printf "binary format: bFLT\n"
	printf "add to your shell rc:\n"
	printf "export PATH=\"/home/src/1v4n/chimera/buildroot-nommu/host/bin:\${PATH}\"\n"
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
		chimera_defconfig
	scripts/config \
		--enable BINFMT_FLAT \
		--enable BINFMT_SCRIPT \
		--disable CMDLINE_FORCE \
		--set-str CMDLINE ""
	make \
		ARCH="${ARCH}" \
		CROSS_COMPILE="${SYSROOT_LINUX}/bin/${TARGET_LINUX}-" \
		olddefconfig
	grep -q '^CONFIG_BINFMT_FLAT=y$' .config
	grep -q '^CONFIG_BINFMT_SCRIPT=y$' .config
	grep -q '^CONFIG_CMDLINE=""$' .config
	make "${JOBS}" \
		ARCH="${ARCH}" \
		CROSS_COMPILE="${SYSROOT_LINUX}/bin/${TARGET_LINUX}-"
	cp arch/riscv/boot/Image "${IMAGE}/kernel.bin"
	printf "linux %s done\n" "${LINUX}"
}

fbusybox() {
	cd "${SRC}"
	[ -f busybox-"${BUSYBOX}".tar.bz2 ] ||
		wget "${BUSYBOX_URL}"
	[ -d busybox-"${BUSYBOX}" ] ||
		tar xjf busybox-"${BUSYBOX}".tar.bz2
	cd busybox-"${BUSYBOX}"
	make \
		CROSS_COMPILE="${SYSROOT_NOMMU}/bin/${TARGET_NOMMU}-" \
		distclean
	make \
		CROSS_COMPILE="${SYSROOT_NOMMU}/bin/${TARGET_NOMMU}-" \
		allnoconfig
	sed -i \
		-e 's/# CONFIG_NOMMU is not set/CONFIG_NOMMU=y/' \
		-e 's/# CONFIG_STATIC is not set/CONFIG_STATIC=y/' \
		-e 's/# CONFIG_HUSH is not set/CONFIG_HUSH=y/' \
		-e 's/# CONFIG_SH_IS_HUSH is not set/CONFIG_SH_IS_HUSH=y/' \
		-e 's/# CONFIG_CAT is not set/CONFIG_CAT=y/' \
		-e 's/# CONFIG_ECHO is not set/CONFIG_ECHO=y/' \
		-e 's/# CONFIG_LS is not set/CONFIG_LS=y/' \
		-e 's/# CONFIG_MKDIR is not set/CONFIG_MKDIR=y/' \
		-e 's/# CONFIG_MKNOD is not set/CONFIG_MKNOD=y/' \
		-e 's/# CONFIG_MOUNT is not set/CONFIG_MOUNT=y/' \
		-e 's/# CONFIG_UMOUNT is not set/CONFIG_UMOUNT=y/' \
		-e 's/# CONFIG_DMESG is not set/CONFIG_DMESG=y/' \
		-e 's/# CONFIG_UNAME is not set/CONFIG_UNAME=y/' \
		-e 's/# CONFIG_HOSTNAME is not set/CONFIG_HOSTNAME=y/' \
		-e 's/# CONFIG_SLEEP is not set/CONFIG_SLEEP=y/' \
		-e 's/# CONFIG_HALT is not set/CONFIG_HALT=y/' \
		-e 's/# CONFIG_POWEROFF is not set/CONFIG_POWEROFF=y/' \
		-e 's/# CONFIG_REBOOT is not set/CONFIG_REBOOT=y/' \
		-e 's/# CONFIG_INIT is not set/CONFIG_INIT=y/' \
		-e 's/# CONFIG_FEATURE_USE_INITTAB is not set/CONFIG_FEATURE_USE_INITTAB=y/' \
		.config
	yes "" |
		make \
			CROSS_COMPILE="${SYSROOT_NOMMU}/bin/${TARGET_NOMMU}-" \
			oldconfig
	grep -q '^CONFIG_NOMMU=y$' .config
	grep -q '^CONFIG_STATIC=y$' .config
	grep -q '^CONFIG_HUSH=y$' .config
	grep -q '^CONFIG_SH_IS_HUSH=y$' .config
	grep -q '^# CONFIG_ASH is not set$' .config
	grep -q '^# CONFIG_SH_IS_ASH is not set$' .config
	make clean
	make "${JOBS}" \
		CROSS_COMPILE="${SYSROOT_NOMMU}/bin/${TARGET_NOMMU}-" \
		CONFIG_EXTRA_LDFLAGS="-Wl,-elf2flt=-r" \
		SKIP_STRIP=y
	magic="$(od -An -tx1 -N4 busybox |
		tr -d ' \n')"
	[ "${magic}" = "62464c54" ] || {
		printf "BusyBox produced invalid binary magic: %s\n" \
			"${magic}" >&2
		exit 1
	}
	rm -rf "${ROOTFS:?}/"*
	make \
		CROSS_COMPILE="${SYSROOT_NOMMU}/bin/${TARGET_NOMMU}-" \
		CONFIG_PREFIX="${ROOTFS}" \
		CONFIG_EXTRA_LDFLAGS="-Wl,-elf2flt=-r" \
		SKIP_STRIP=y \
		install
	magic="$(od -An -tx1 -N4 "${ROOTFS}/bin/busybox" |
		tr -d ' \n')"
	[ "${magic}" = "62464c54" ] || {
		printf "Installed BusyBox has invalid binary magic: %s\n" \
			"${magic}" >&2
		exit 1
	}
	printf "BusyBox %s done\n" "${BUSYBOX}"
	printf "Binary format: bFLT\n"
}

fimage() {
	mkdir -p \
		"${ROOTFS}/etc/init.d" \
		"${ROOTFS}/proc" \
		"${ROOTFS}/sys" \
		"${ROOTFS}/dev" \
		"${ROOTFS}/tmp" \
		"${IMAGE}"
	chmod 1777 "${ROOTFS}/tmp"
	rm -f \
		"${ROOTFS}/dev/console" \
		"${ROOTFS}/dev/null"
	mknod \
		-m 600 \
		"${ROOTFS}/dev/console" \
		c 5 1
	mknod \
		-m 666 \
		"${ROOTFS}/dev/null" \
		c 1 3
	cat > "${ROOTFS}/etc/inittab" << 'EOF'
::sysinit:/etc/init.d/rcS
::askfirst:-/bin/sh
::ctrlaltdel:/sbin/reboot
::shutdown:/bin/umount -a -r
EOF
	cat > "${ROOTFS}/etc/init.d/rcS" << 'EOF'
#!/bin/sh

mount -t proc proc /proc
mount -t sysfs sysfs /sys
mount -t devtmpfs devtmpfs /dev

hostname chimera

echo
echo "Chimera RV32 NOMMU"
echo
EOF
	chmod +x "${ROOTFS}/etc/init.d/rcS"
	cd "${ROOTFS}"
	find . -print0 |
		sort -z |
		cpio \
			--null \
			-H newc \
			-o |
		gzip -9n > "${IMAGE}/rootfs.cpio.gz"
	printf "image ready: %s/rootfs.cpio.gz\n" "${IMAGE}"
	ls -lh "${IMAGE}/rootfs.cpio.gz"
}

fqemu() {
	[ -f "${KERNEL}/linux-${LINUX}/arch/riscv/boot/Image" ]
	[ -f "${IMAGE}/rootfs.cpio.gz" ]
	qemu-system-riscv32 \
		-machine virt \
		-cpu rv32 \
		-smp 1 \
		-m 128M \
		-nographic \
		-bios none \
		-kernel "${KERNEL}/linux-${LINUX}/arch/riscv/boot/Image" \
		-initrd "${IMAGE}/rootfs.cpio.gz" \
		-append "earlycon=uart8250,mmio,0x10000000 console=ttyS0,115200 rdinit=/sbin/init"
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
	qemu)
		fqemu
		;;
	all)
		fdirs && \
		ftoolchain && \
		ftoolchain_linux && \
		ftoolchain_nommu && \
		flinux && \
		fbusybox && \
		fimage
		;;
	*)
		printf "unsupported stage: %s\n" "${ARG}"
		fusage
		;;
esac
