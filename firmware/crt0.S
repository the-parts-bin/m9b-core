// Startup code: set up the stack, copy .data from flash to RAM, clear
// .bss, call main().

.section .text.start
.global _start
_start:
    la   sp, _stack_top

    la   t0, _data_start
    la   t1, _data_end
    la   t2, _data_load
copy_data:
    bge  t0, t1, copy_data_done
    lw   t3, 0(t2)
    sw   t3, 0(t0)
    addi t0, t0, 4
    addi t2, t2, 4
    j    copy_data
copy_data_done:

    la   t0, _bss_start
    la   t1, _bss_end
clear_bss:
    bge  t0, t1, clear_bss_done
    sw   zero, 0(t0)
    addi t0, t0, 4
    j    clear_bss
clear_bss_done:

    call main

halt:
    j halt
