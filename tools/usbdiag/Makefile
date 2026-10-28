# USB diagnostics, run with: ../run.py build/<name>.bin --listen 10
CROSS  ?= riscv64-unknown-elf-
CFLAGS := -march=rv32im_zicsr -mabi=ilp32 -Os -ffreestanding -nostdlib -Wall -Wextra -Wl,--no-warn-rwx-segments -I../../firmware
ifdef PORT
CFLAGS += -DPORT=$(PORT)
endif
PROGS  := usbstate usbbus usbreport

.PRECIOUS: build/%.elf

all: $(PROGS:%=build/%.bin)

build/%.elf: %.c common.h link.ld | build
	$(CROSS)gcc $(CFLAGS) -T link.ld $< -lgcc -o $@

build/%.bin: build/%.elf
	$(CROSS)objcopy -O binary $< $@

build:
	mkdir -p build

clean:
	rm -rf build
