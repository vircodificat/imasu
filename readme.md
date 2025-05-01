## imasu

**imasu** *(います 🇯🇵 to be, to exist, animate)* is a small RISC-V system emulator.

Features of the emulator include:
- 64-bit RISC-V hart, implementing RV64**IMASU** and Privileged ISA version **1.12** *(20211203)*
- **Sv39** Memory Management Unit
- standard platform devices, such as a **CLINT** Timer and **PLIC** Interrupt Controller
- emulated NS8250 UART for terminal input and output
- per-device threads and transient sleep on `wfi` for low idle host CPU usage
- Syscon device for system poweroff
- runtime **Device tree** blob generation
- written **entirely in Zig** with no external dependencies, even at compile-time!

## Compiling and usage

**imasu** is written in the Zig language using the latest development branch (currently 0.15.0-dev).

run `zig build [-Doptimize=...]` to compile the emulator.

`zig build install [...] --prefix-exe-dir <directory>` will compile and place the `imasu64` binary in your install directory of choice.

run the `imasu64` binary or `zig build run` with `-h`/`--help` for help and usage information.

### Running OpenSBI

**imasu** can run a generic [OpenSBI](https://github.com/riscv-software-src/opensbi) firmware image:

`make CROSS_COMPILE=<...> PLATFORM_RISCV_XLEN=64 PLATFORM_RISCV_ISA=rv64ima_zicsr_zifencei PLATFORM=generic [...]`

then run the resulting `fw_payload.bin` with the emulator.

see [OpenSBI > Required Toolchain and Packages](https://github.com/riscv-software-src/opensbi/blob/master/README.md#required-toolchain-and-packages) for cross-compilation toolchain requirements.

### Running no-MMU Linux

Linux can optionally be ran freestanding in M-mode for constrained systems without MMU support.
The following kernel config options are required for **imasu**:
- `CONFIG_NONPORTABLE=y`, and `CONFIG_MMU=n` as we want to run in M-mode with no memory management unit support
- `CONFIG_RISCV_EMULATED_UNALIGNED_ACCESS=y` as Linux will run in M-mode, and thus needs to emulate misaligned stores and loads
- `CONFIG_PHYS_RAM_BASE_FIXED=y`, `CONFIG_PHYS_RAM_BASE=0x80000000` to set the base address to start of the emulator's main memory
- `CONFIG_BLK_DEV_INITRD=y` as **imasu** does not implement any emulated storage devices, the root filesystem must be baked into the image
- `CONFIG_TTY=y`, `CONFIG_VT=y`, `CONFIG_SERIAL_8250=y`, `CONFIG_SERIAL_8250_CONSOLE=y` for NS8250 UART support so that Linux can display to the terminal and read user input, `CONFIG_TTY_PRINTK` so that the boot process is also printed to the terminal

## TODOs

- document building OpenSBI with S-mode Linux payload
- option to compile a 32-bit RV32 emulator
- compile-time options to disable or enable parts of the ISA
- ELF loading

## License

GPLv2 only, see `license`
