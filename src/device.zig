// MMIO-accessible device interface type

const riscv = @import("riscv.zig");
const CLINT = @import("devices/clint.zig");
const PLIC = @import("devices/plic.zig");
const ROM = @import("devices/rom.zig");
const Syscon = @import("devices/syscon.zig");
const UART = @import("devices/uart.zig");
const std = @import("std");

const Device = @This();

kind: union(enum) { // device type
    clint: *CLINT,
    plic: *PLIC,
    rom: *ROM,
    syscon: *Syscon,
    uart: *UART,
},
mmio_base: u64, // start of device mmio region
mmio_len: u64, // length of device mmio region

// read naturally-aligned power-of-two bytes from device register reg_addr
pub fn mmio_reg_read(dev: *Device, comptime T: type, reg_addr: u64) ?T {
    return switch (dev.kind) {
        inline else => |impl| impl.mmio_reg_read(T, reg_addr),
    };
}

// write naturally-aligned power-of-two bytes to device register reg_addr
pub fn mmio_reg_write(dev: *Device, comptime T: type, reg_addr: u64, v: T) ?void {
    return switch (dev.kind) {
        inline else => |impl| impl.mmio_reg_write(T, reg_addr, v),
    };
}
