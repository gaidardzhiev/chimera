#!/bin/sh
#Copyright (C) 2026 Ivan Gaydardzhiev
#Licensed under the GPL-3.0-only

set -eu

CHIMERA="${PWD}"
IMAGE="${CHIMERA}/image"
TMP="${CHIMERA}/.verify"
NS="${NS:-4}"
STEPS="${STEPS:-400000000}"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
NONE='\033[0m'

fstamp() {
	date '+%H:%M:%S'
}

fpass() {
	printf "%s  ${GREEN}PASSED${NONE}  %s\n" "$(fstamp)" "${1}"
}

ffail() {
	printf "%s  ${RED}FAILED${NONE}  %s\n" "$(fstamp)" "${1}"
	exit "${2}"
}

fskip() {
	printf "%s  ${YELLOW}SKIP  ${NONE}  %s\n" "$(fstamp)" "${1}"
}

fmkbin() {
	printf '%b' '\0267\0002\0000\0020\0023\0005\0360\0006\0043\0200\0242\0000\0023\0005\0260\0006\0043\0200\0242\0000\0023\0005\0240\0000\0043\0200\0242\0000\0023\0005\0000\0000\0163\0000\0000\0000' > "${TMP}/ok.bin"
	printf '%b' '\0267\0002\0000\0200\0043\0240\0002\0000\0163\0000\0000\0000' > "${TMP}/rowrite.bin"
}

ft1_build_cpu() {
	make cpu > "${TMP}/build.log" 2>&1 ||
		ffail "ft1 build cpu emulator" 11
	[ -x "${CHIMERA}/chimera-cpu" ] ||
		ffail "ft1 build cpu emulator" 11
	fpass "ft1 build cpu emulator"
}

ft2_smoke() {
	"${CHIMERA}/chimera-cpu" "${TMP}/ok.bin" 1 \
		< /dev/null > "${TMP}/ok.out" 2> "${TMP}/ok.err" ||
		ffail "ft2 bare metal smoke test" 12
	[ "$(cat "${TMP}/ok.out")" = "ok" ] ||
		ffail "ft2 bare metal smoke test (wrong output)" 12
	grep -q "exit pc=0x80000024 steps=9 out=3 retval=0" "${TMP}/ok.err" ||
		ffail "ft2 bare metal smoke test (wrong final state)" 12
	fpass "ft2 bare metal smoke test"
}

ft3_dtb() {
	./run.sh mkdtb > "${TMP}/mkdtb.log" 2>&1 ||
		ffail "ft3 device tree" 13
	magic="$(od -A n -N 4 -t x1 "${IMAGE}/chimera.dtb" | tr -d ' \n')"
	[ "${magic}" = "d00dfeed" ] ||
		ffail "ft3 device tree (bad magic ${magic})" 13
	total="$(od -A n -j 4 -N 4 -t u4 --endian=big "${IMAGE}/chimera.dtb" | tr -d ' ')"
	actual="$(wc -c < "${IMAGE}/chimera.dtb" | tr -d ' ')"
	[ "${total}" = "${actual}" ] ||
		ffail "ft3 device tree (totalsize ${total} != file ${actual})" 13
	rsv="$(od -A n -j 16 -N 4 -t u4 --endian=big "${IMAGE}/chimera.dtb" | tr -d ' ')"
	[ "${rsv}" -lt "${actual}" ] ||
		ffail "ft3 device tree (rsvmap offset ${rsv} outside file)" 13
	fpass "ft3 device tree"
}

ft4_cpu_boot() {
	./run.sh pack > "${TMP}/pack.log" 2>&1 ||
		ffail "ft4 cpu boot to shell" 14
	CHIMERA_MAX_STEPS="${STEPS}" "${CHIMERA}/chimera-cpu" \
		"${IMAGE}/kernel.bin" "${IMAGE}/initrd.bin" "${IMAGE}/chimera.dtb" 1 \
		< /dev/null > "${TMP}/cpu.out" 2> "${TMP}/cpu.log" ||
		ffail "ft4 cpu boot to shell" 14
	grep -q "Run /sbin/init as init process" "${TMP}/cpu.log" ||
		ffail "ft4 cpu boot to shell (init never ran)" 14
	grep -q "Chimera RV32 NOMMU" "${TMP}/cpu.log" ||
		ffail "ft4 cpu boot to shell (rcS never ran)" 14
	grep -q "~ #" "${TMP}/cpu.log" ||
		ffail "ft4 cpu boot to shell (no prompt)" 14
	fpass "ft4 cpu boot to shell"
}

ft5_determinism() {
	CHIMERA_MAX_STEPS="${STEPS}" "${CHIMERA}/chimera-cpu" \
		"${IMAGE}/kernel.bin" "${IMAGE}/initrd.bin" "${IMAGE}/chimera.dtb" 1 \
		< /dev/null > "${TMP}/cpu2.out" 2>/dev/null ||
		ffail "ft5 cpu boot is deterministic" 15
	cmp -s "${TMP}/cpu.out" "${TMP}/cpu2.out" ||
		ffail "ft5 cpu boot is deterministic (runs differ)" 15
	fpass "ft5 cpu boot is deterministic"
}

ft6_shared_write() {
	c++ -O2 -DCHIMERA_CPU -DRAM_SIZE=33554432u -DRO_SIZE=4096u \
		-x c++ -o "${TMP}/chimera-ro" chimera.cu > "${TMP}/build-ro.log" 2>&1 ||
		ffail "ft6 shared region rejects writes" 16
	"${TMP}/chimera-ro" "${TMP}/rowrite.bin" 1 \
		< /dev/null > /dev/null 2> "${TMP}/ro.err" ||
		ffail "ft6 shared region rejects writes" 16
	grep -q "write to shared read-only region" "${TMP}/ro.err" ||
		ffail "ft6 shared region rejects writes (no fault raised)" 16
	grep -q "addr=0x80000000" "${TMP}/ro.err" ||
		ffail "ft6 shared region rejects writes (wrong fault address)" 16
	fpass "ft6 shared region rejects writes"
}

ft10_console_input() {
	command -v script > /dev/null 2>&1 || {
		fskip "ft10 terminal input reaches the guest shell (no script)"
		return 0
	}
	(sleep 12; printf '\necho AA$((21+21))BB\n'; sleep 10) |
		script -q -c "env CHIMERA_MAX_STEPS=2000000000 ${CHIMERA}/chimera-cpu ${IMAGE}/kernel.bin ${IMAGE}/initrd.bin ${IMAGE}/chimera.dtb 1" \
		/dev/null > "${TMP}/tty.out" 2>&1 || true
	n="$(tr -d '\r' < "${TMP}/tty.out" | grep -c "AA42BB" || true)"
	[ "${n}" -ge 2 ] ||
		ffail "ft10 terminal input reaches the guest shell (shell never ran it)" 20
	fpass "ft10 terminal input reaches the guest shell"
}

ft7_gpu_build() {
	command -v nvcc > /dev/null 2>&1 || {
		fskip "ft7 build cuda emulator (no nvcc)"
		return 0
	}
	make > "${TMP}/build-cuda.log" 2>&1 ||
		ffail "ft7 build cuda emulator" 17
	[ -x "${CHIMERA}/chimera" ] ||
		ffail "ft7 build cuda emulator" 17
	fpass "ft7 build cuda emulator"
}

ft8_gpu_matches_cpu() {
	[ -x "${CHIMERA}/chimera" ] || {
		fskip "ft8 cuda boot matches cpu boot"
		return 0
	}
	CHIMERA_MAX_STEPS="${STEPS}" "${CHIMERA}/chimera" \
		"${IMAGE}/kernel.bin" "${IMAGE}/initrd.bin" "${IMAGE}/chimera.dtb" 1 \
		< /dev/null > "${TMP}/gpu1.out" 2> "${TMP}/gpu1.log" ||
		ffail "ft8 cuda boot matches cpu boot" 18
	cmp -s "${TMP}/cpu.out" "${TMP}/gpu1.out" ||
		ffail "ft8 cuda boot matches cpu boot (output differs)" 18
	fpass "ft8 cuda boot matches cpu boot"
}

ft9_gpu_scale() {
	[ -x "${CHIMERA}/chimera" ] || {
		fskip "ft9 ${NS} namespaces each boot independently"
		return 0
	}
	CHIMERA_MAX_STEPS="${STEPS}" "${CHIMERA}/chimera" \
		"${IMAGE}/kernel.bin" "${IMAGE}/initrd.bin" "${IMAGE}/chimera.dtb" "${NS}" \
		< /dev/null > "${TMP}/gpuN.out" 2> "${TMP}/gpuN.log" ||
		ffail "ft9 ${NS} namespaces each boot independently" 19
	n="$(grep -c "Chimera RV32 NOMMU" "${TMP}/gpuN.out" || true)"
	[ "${n}" = "${NS}" ] ||
		ffail "ft9 ${NS} namespaces each boot independently (${n} reached rcS)" 19
	expect="$(wc -c < "${TMP}/gpu1.out" | tr -d ' ')"
	actual="$(wc -c < "${TMP}/gpuN.out" | tr -d ' ')"
	[ "${actual}" = "$((expect * NS))" ] ||
		ffail "ft9 ${NS} namespaces each boot independently (output not uniform)" 19
	fpass "ft9 ${NS} namespaces each boot independently"
}

mkdir -p "${TMP}"
fmkbin

printf "chimera verify: NS=%s STEPS=%s\n" "${NS}" "${STEPS}"

ft1_build_cpu &&
	ft2_smoke &&
	ft3_dtb &&
	ft4_cpu_boot &&
	ft5_determinism &&
	ft6_shared_write &&
	ft10_console_input &&
	ft7_gpu_build &&
	ft8_gpu_matches_cpu &&
	ft9_gpu_scale &&
	printf "%s  ${GREEN}ALL PASSED${NONE}\n" "$(fstamp)"
