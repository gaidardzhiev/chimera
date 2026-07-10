.section .text
.global _start

.equ UART_BASE,     0x10000000
.equ UART_TX,       0x00
.equ UART_RX,       0x00
.equ UART_LSR,      0x05
.equ UART_LSR_DR,   0x01
.equ UART_LSR_THRE, 0x20

_start:
	la	a0, msg_ready
	jal	ra, uart_puts

echo_loop:
	jal	ra, uart_getc
	mv	a2, a0
	jal	ra, uart_putc
	j	echo_loop

uart_getc:
	li	t0, UART_BASE
rx_wait:
	lb	t1, UART_LSR(t0)
	andi	t1, t1, UART_LSR_DR
	beqz	t1, rx_wait
	lb	a0, UART_RX(t0)
	ret

uart_putc:
	li	t0, UART_BASE
tx_wait:
	lb	t1, UART_LSR(t0)
	andi	t1, t1, UART_LSR_THRE
	beqz	t1, tx_wait
	sb	a2, UART_TX(t0)
	ret

uart_puts:
	mv	t4, ra
puts_loop:
	lb	a2, 0(a0)
	beqz	a2, puts_done
	jal	ra, uart_putc
	addi	a0, a0, 1
	j	puts_loop
puts_done:
	mv	ra, t4
	ret

.section .rodata
msg_ready:
	.asciz "chimera uart echo ready\n"
