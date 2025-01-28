// read-only memory region

const Exception = @import("../exception.zig").Exception;
const std = @import("std");

const ROM = @This();

mem: []u8, // read-only memory stored by this device

pub fn mmio_reg_read(rom: *ROM, comptime T: type, reg_addr: u64) !T {
    // memory calling this has already checked that the
    // access is within bounds, so just perform readInt
    const sz = @divExact(@typeInfo(T).int.bits, 8);
    return std.mem.readInt(T, rom.mem[reg_addr .. reg_addr + sz][0..sz], .little);
}

pub fn mmio_reg_write(_: *ROM, comptime T: type, _: u64, _: T) !void {
    return Exception.StoreAccessFault;
}

pub fn run(_: *ROM) void {
    unreachable;
}
