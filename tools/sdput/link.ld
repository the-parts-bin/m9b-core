/* sdput: loaded at 0x800000 (the start of PSRAM) by tools/run.py; stack below 0x900000. */
ENTRY(_start)
SECTIONS {
  . = 0x800000;
  .text : { *(.text.start) *(.text*) *(.rodata*) *(.srodata*) *(.data*) *(.sdata*) }
  .bss (NOLOAD) : { __bss_start = .; *(.bss*) *(.sbss*) *(COMMON) . = ALIGN(4); __bss_end = .; }
}
