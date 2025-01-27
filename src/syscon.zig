const Exception = @import("exception.zig").Exception;
const std = @import("std");

const Syscon = @This();

pub const mmio_len = 0x4;

pub fn mmio_reg_read(_: *Syscon, comptime T: type, reg_addr: u64) !T {
    if (T != u32 or reg_addr != 0) return Exception.LoadAccessFault;
    return 0;
}

pub fn mmio_reg_write(_: *Syscon, comptime T: type, reg_addr: u64, v: T) !void {
    if (T != u32 or reg_addr != 0) return Exception.StoreAccessFault;
    if (v == 0x0000DEAD) std.process.exit(0);
    return;
}
