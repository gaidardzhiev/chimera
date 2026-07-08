.section .text
.global _start

.equ UART_BASE,    0x10000000
.equ UART_TX,      0x00
.equ UART_LSR,     0x05
.equ UART_LSR_THRE,0x20

.equ CLINT_BASE,   0x02000000
.equ MTIME,        0x0000BFF8
.equ MTIMECMP,     0x00004000

.equ TIMER_INTERVAL, 10000000

_start:
	la	t0, mtvec_handler
	csrw	mtvec, t0

	li	t0, CLINT_BASE
	li	t1, MTIME
	add	t1, t0, t1
	lw	t2, 0(t1)
	li	t3, TIMER_INTERVAL
	add	t2, t2, t3
	li	t1, MTIMECMP
	add	t1, t0, t1
	sw	t2, 0(t1)

	li	t0, 0x80
	csrw	mie, t0

	li	t0, 0x8
	csrw	mstatus, t0

wait:
	wfi
	j	wait

mtvec_handler:
	csrr	t0, mcause
	li	t1, 0x80000007
	bne	t0, t1, halt

	la	a0, msg_tick
	jal	ra, uart_puts

	li	t0, CLINT_BASE
	li	t1, MTIME
	add	t1, t0, t1
	lw	t2, 0(t1)
	li	t3, TIMER_INTERVAL
	add	t2, t2, t3
	li	t1, MTIMECMP
	add	t1, t0, t1
	sw	t2, 0(t1)

	mret

halt:
	la	a0, msg_halt
	jal	ra, uart_puts
	j	halt

uart_puts:
	mv	t4, ra
putc_loop:
	lb	a2, 0(a0)
	beqz	a2, puts_done
	jal	ra, uart_putc
	addi	a0, a0, 1
	j	putc_loop
puts_done:
	mv	ra, t4
	ret

uart_putc:
	li	t0, UART_BASE
uart_wait:
	lb	t1, UART_LSR(t0)
	andi	t1, t1, UART_LSR_THRE
	beqz	t1, uart_wait
	sb	a2, UART_TX(t0)
	ret

.section .rodata
msg_tick:
	.asciz "tick\n"
msg_halt:
	.asciz "unexpected trap\n"
