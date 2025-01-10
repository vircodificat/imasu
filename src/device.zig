// MMIO-accessible devices

const ROM = @import("rom.zig");
const std = @import("std");

const Device = @This();

kind: union(enum) { // device type
    rom: *ROM,
},
mmio_base: u64, // start of device mmio region
mmio_len: u64, // length of device mmio region

// read naturally-aligned power-of-two bytes from device register reg_addr
pub fn mmio_reg_read(dev: *Device, comptime T: type, reg_addr: u64) !T {
    return switch (dev.kind) {
        inline else => |impl| impl.mmio_reg_read(T, reg_addr),
    };
}

// write naturally-aligned power-of-two bytes to device register reg_addr
pub fn mmio_reg_write(dev: *Device, comptime T: type, reg_addr: u64, v: T) !void {
    return switch (dev.kind) {
        inline else => |impl| impl.mmio_reg_write(T, reg_addr, v),
    };
}

// run the device
pub fn run(dev: *Device) void {
    switch (dev.kind) {
        inline else => |impl| impl.run(),
    }
}
