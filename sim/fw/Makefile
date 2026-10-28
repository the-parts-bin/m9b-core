# Builds sim_main.c into ufm_init.hex (the user flash contents, 32-bit
# words for $readmemh) for sim/tb_soc.v, using the real firmware's startup
# code and linker script.
CROSS   ?= riscv64-unknown-elf-
CC      := $(CROSS)gcc
OBJCOPY := $(CROSS)objcopy

FW := ../../firmware
CFLAGS  := -march=rv32im_zba_zicbop_zicsr_zifencei_zicbom -mabi=ilp32 -Os -ffreestanding -fno-builtin -I$(FW) \
           -nostdlib -nostartfiles -Wall -Wextra
LDFLAGS := -T $(FW)/link.ld -Wl,--gc-sections

all: ufm_init.hex

firmware.elf: $(FW)/crt0.S sim_main.c $(FW)/link.ld
	$(CC) $(CFLAGS) $(LDFLAGS) $(FW)/crt0.S sim_main.c -lgcc -o $@

firmware.bin: firmware.elf
	$(OBJCOPY) -O binary $< $@

ufm_init.hex: firmware.bin $(FW)/makehex.py
	python3 $(FW)/makehex.py firmware.bin ufm_init.hex 19456 4

clean:
	rm -f firmware.elf firmware.bin ufm_init.hex boot_ram_init.vh

.PHONY: all clean
