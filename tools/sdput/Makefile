# sdput: writes files to the SD card through the board (see sdput.c and
# sdput.py). Built with FatFs's write support; the core firmware and Doom
# stay read-only.
CROSS  ?= riscv64-unknown-elf-
FW     := ../../firmware
CFLAGS := -march=rv32im_zba_zicbop_zicsr_zicbom -mabi=ilp32 -Os -ffreestanding -nostdlib -Wall -Wextra \
          -Wno-unused-parameter -Wno-sign-compare -DFF_FS_READONLY=0 -DFF_USE_CHMOD=1 -I$(FW) -I$(FW)/include -I$(FW)/fatfs \
          -Wl,--no-warn-rwx-segments -Wl,--gc-sections -ffunction-sections -fdata-sections
SRCS   := sdput.c $(FW)/sd.c $(FW)/diskio.c $(FW)/libc.c $(FW)/fatfs/ff.c $(FW)/fatfs/ffunicode.c

build/sdput.bin: build/sdput.elf
	$(CROSS)objcopy -O binary $< $@

build/sdput.elf: $(SRCS) $(FW)/sd.h $(FW)/fatfs/ffconf.h link.ld | build
	$(CROSS)gcc $(CFLAGS) -T link.ld $(SRCS) -lgcc -o $@

build:
	mkdir -p build

clean:
	rm -rf build
