# Builds hello.c (+ the SD driver and FatFs) into firmware.bin, a raw image for the user flash (written
# with the bitstream by ../build.sh: openFPGALoader --user-flash). Also
# writes ufm_init.hex (32-bit words, $readmemh) for the simulations.
# Requires a riscv32/riscv64-elf GCC toolchain.

CROSS   ?= riscv64-unknown-elf-
CC      := $(CROSS)gcc
OBJCOPY := $(CROSS)objcopy
OBJDUMP := $(CROSS)objdump

MARCH := rv32im_zba_zicbop_zicsr_zifencei_zicbom
MABI  := ilp32

CFLAGS  := -march=$(MARCH) -mabi=$(MABI) -Os -ffreestanding -fno-builtin -Iinclude \
           -nostdlib -nostartfiles -Wall -Wextra
LDFLAGS := -T link.ld -Wl,--gc-sections -Wl,-Map=firmware.map

UFM_BYTES := 77824   # 76 KB

all: firmware.bin

SRCS := crt0.S hello.c boot.c sd.c diskio.c loader.c libc.c fatfs/ff.c fatfs/ffunicode.c

firmware.elf: $(SRCS) assets.h boot.h sd.h loader.h fatfs/ff.h fatfs/ffconf.h fatfs/diskio.h link.ld
	$(CC) $(CFLAGS) $(LDFLAGS) $(SRCS) -lgcc -o $@

firmware.bin: firmware.elf
	$(OBJCOPY) -O binary $< $@
	@size=$$(stat -c %s $@); echo "firmware.bin: $$size of $(UFM_BYTES) bytes"; \
	  test $$size -le $(UFM_BYTES) || { echo "too big for the user flash" >&2; exit 1; }

ufm_init.hex: firmware.bin makehex.py
	python3 makehex.py firmware.bin $@ 19456 4

disasm: firmware.elf
	$(OBJDUMP) -d firmware.elf

clean:
	rm -f firmware.elf firmware.bin firmware.map ufm_init.hex boot_ram_init.vh

.PHONY: all disasm clean

# The boot screen's fonts, palette and logo (needs Python with PIL; the
# generated file is kept in the repository, and kept as it is without PIL:
# a fresh checkout can leave it older than its sources).
assets.h: gen_assets.py fonts/PixelOperator.ttf fonts/PixelOperator-Bold.ttf
	if python3 -c 'import PIL' 2> /dev/null; then python3 gen_assets.py $@; \
	else echo "no PIL: keeping the $@ in the repository"; touch $@; fi
