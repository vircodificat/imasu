## imasu

**imasu** *(🇯🇵 to be, to exist, animate)* is a small RISC-V system emulator

features of the emulator include:
- a 64-bit RISC-V hart, implementing RV64**IMAU**
- standard platform devices, such as a CLINT timer and PLIC interrupt controller
- emulated NS8250 UART for terminal input and output
- written entirely in Zig with no external dependencies such as libc

The system is capable of running no-MMU builds of Linux, such as Buildroot

## Compiling and Running

imasu is written in the `zig` language using the latest development branch, and requires the devicetree compiler `dtc` present at build time

`zig build -Doptimize=ReleaseSmall --prefix-exe-dir <bin directory>` will compile and place the `imasu64` binary in your directory of choice

run the resulting binary (or append to `zig build run`) with a path to a system image file to run it on the emulator

### Building Linux

imasu needs the following config options in your Linux kernel:
- `CONFIG_NONPORTABLE=y`, and `CONFIG_MMU=n` as imasu does not support S-mode and does not implement an MMU
- `CONFIG_RISCV_EMULATED_UNALIGNED_ACCESS=y` as Linux will run in M-mode and needs to emulate misaligned stores and loads
- `CONFIG_PHYS_RAM_BASE_FIXED=y`, `CONFIG_PHYS_RAM_BASE=0x80000000` to set the base address to start of main memory in the emulator
- `CONFIG_BLK_DEV_INITRD=y` as imasu does not implement any emulated storage devices the root filesystem must be baked into the image
- `CONFIG_TTY=y`, `CONFIG_VT=y`, `CONFIG_SERIAL_8250=y`, `CONFIG_SERIAL_8250_CONSOLE=y` for NS8250 UART support so that Linux can display to the terminal and read user input, `CONFIG_TTY_PRINTK` so that the boot process is also printed to the terminal

## TODOs

- System poweroff device (SYSCON)
- Supervisor (S) mode support, so we can run `opensbi`
- A Memory Management Unit (MMU)
- option to compile a 32-bit RV32 emulator
- compile options to disable or enable parts of the ISA
- ELF loading

## License

GPLv2 only, see `license`
