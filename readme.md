## imasu

**imasu** *(います 🇯🇵 to be, to exist, animate)* is a small RISC-V system emulator.

Features of the emulator include:
- 64-bit RISC-V hart, implementing RV64**IMASU** and Privileged ISA version **1.12** *(20211203)*
- **Sv39** Memory Management Unit
- standard platform devices, such as a **CLINT** Timer and **PLIC** Interrupt Controller
- emulated NS8250 UART for terminal input and output
- per-device threads, sleep on `wfi` for low idle host CPU usage
- Syscon device for system poweroff
- runtime **Device tree** blob generation
- written **entirely in Zig** with no external dependencies, even at compile-time!

## Compiling and usage

**imasu** is written in the Zig language using the latest development branch (currently 0.15.0-dev).

run `zig build [-Doptimize=...]` to compile the emulator.

`zig build install [...] --prefix-exe-dir <directory>` will compile and place the `imasu64` binary in your install directory of choice.

run the `imasu64` binary or `zig build run` with `-h`/`--help` for help and usage information.

the rest of this readme contains instructions for building various software to run on **imasu**, as well as other emulators!

### Running OpenSBI

**imasu** can run a generic [OpenSBI](https://github.com/riscv-software-src/opensbi) firmware image:

`make CROSS_COMPILE=<...> PLATFORM_RISCV_XLEN=64 PLATFORM_RISCV_ISA=rv64ima_zicsr_zifencei PLATFORM=generic [...]`

then run the resulting `fw_payload.bin` with the emulator.

see [OpenSBI > Required Toolchain and Packages](https://github.com/riscv-software-src/opensbi/blob/master/README.md#required-toolchain-and-packages) for cross-compilation toolchain requirements.

### Running Linux

**imasu** can run the Linux kernel with a baked-in root filesystem, bundled as an OpenSBI firmware payload.

the following kernel config options are required:
- `CONFIG_NONPORTABLE=y` needs to be set to set `CONFIG_RISCV_ISA_C=n`
- `CONFIG_BLK_DEV_INITRD=y` as **imasu** does not (yet!) implement any emulated storage devices, the root filesystem must be baked into the image. A path to the root filesystem cpio archive should be given to `CONFIG_INITRAMFS_SOURCE`
- `CONFIG_TTY=y`, `CONFIG_VT=y`, `CONFIG_SERIAL_8250=y`, `CONFIG_SERIAL_8250_CONSOLE=y` for TTY and NS8250 UART support so that Linux can display to the terminal and read user input, `CONFIG_TTY_PRINTK` so that the boot process is also printed to the terminal

once the kernel has been built, OpenSBI can be built to include it as a payload:

`make [...] FW_PAYLOAD=y FW_PAYLOAD_PATH=<path to kernel 'Image' file>`

then run the resulting `fw_payload.bin` with the emulator.

### Running no-MMU Linux

Linux can optionally be ran freestanding in M-mode for constrained systems without MMU support and without SBI or additional firmware support.

the following kernel config changes are required:
- `CONFIG_MMU=n` as we want to run in M-mode with no memory management unit support
- `CONFIG_RISCV_EMULATED_UNALIGNED_ACCESS=y` as Linux will run in M-mode, and thus needs to emulate misaligned stores and loads itself

### Running U-Boot

**imasu** can run the U-boot bootloader in M-mode (`RISCV_MMODE=y`), built for the QEMU virt machine (`TARGET_QEMU_VIRT=y`), with the missing ISA extensions (C, F, Zbb...) disabled.

build with `make CROSS_COMPILE=<...> [...]`

then run the resulting `u-boot.bin` with the emulator.

as of now there is little purpose in running U-boot, as there are no boot media sources outside of what is loaded into memory at emulator boot.

## TODOs

- VirtIO Disk device, so the filesystem does not need to be bundled with the kernel, to be able to run full Linux distros and boot with u-boot, to be able to run xv6, etc...
- testing with RISCOF, document testing with riscv-tests
- option to compile a 32-bit RV32 emulator
- compile-time options to disable or enable parts of the ISA
- ELF loading
- WASM demo?

## License

GPLv2 only, see `license`
