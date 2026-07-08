.section .text
.global _start

.equ UART_BASE, 0x10000000
.equ UART_TX,   0x00
.equ UART_LSR,  0x05
.equ UART_LSR_THRE, 0x20

_start:
	la	a0, msg
	la	a1, msg_end

loop:
	beq	a0, a1, done
	lb	a2, 0(a0)
	jal	ra, uart_putc
	addi	a0, a0, 1
	j	loop

done:
	li	a0, 0
	li	a7, 93
	ecall

uart_putc:
	li	t0, UART_BASE
wait:
	lb	t1, UART_LSR(t0)
	andi	t1, t1, UART_LSR_THRE
	beqz	t1, wait
	sb	a2, UART_TX(t0)
	ret

.section .rodata
msg:
	.ascii "chimera\n"
msg_end:
