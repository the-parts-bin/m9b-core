/*
 * Linker script for the m9b SoC.
 *
 * Code and read-only data are executed and read in place from the user
 * flash at 0x00000000 (76 KB, cached through the L1s). Writable data,
 * .bss and the stack live in the top 128 KB of PSRAM (cached): crt0.S
 * copies .data there from its load address in flash and clears .bss.
 * Programs load from the start of PSRAM (loader.h: LOAD_BASE, up to the
 * boot screen's framebuffer at +7.5 MB) and, once started, have all of it:
 * their own stack takes the top 128 KB again.
 */
ENTRY(_start)

MEMORY
{
    FLASH (rx)  : ORIGIN = 0x00000000, LENGTH = 76K
    RAM   (rwx) : ORIGIN = 0x00FE0000, LENGTH = 128K
}

SECTIONS
{
    .text : {
        KEEP(*(.text.start))
        *(.text*)
    } > FLASH

    .rodata : {
        *(.rodata*)
        *(.srodata*)
    } > FLASH

    .data : ALIGN(4) {
        _data_start = .;
        *(.data*)
        *(.sdata*)
        . = ALIGN(4);
        _data_end = .;
    } > RAM AT > FLASH
    _data_load = LOADADDR(.data);

    .bss (NOLOAD) : ALIGN(4) {
        _bss_start = .;
        *(.sbss*)   /* small variables: GCC puts these apart on RISC-V */
        *(.bss*)
        *(COMMON)
        . = ALIGN(4);
        _bss_end = .;
    } > RAM

    _stack_top = ORIGIN(RAM) + LENGTH(RAM);
}
