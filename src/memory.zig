// Interfaces to physical memory

const Device = @import("device.zig");
const std = @import("std");

const Memory = @This();

mem: []u8, // ram
devices: []*Device, // mmio devices

pub const mem_base: u64 = 0x8000_0000; // lowest address of ram

pub fn create(mem: []u8) Memory {
    std.debug.assert(mem.len % 4096 == 0);
    return Memory{
        .mem = mem,
        .devices = undefined,
    };
}

// return whether [addr,addr+sz) lies within [base,base+len)
inline fn access_bounded(addr: u64, sz: u64, base: u64, len: u64) bool {
    return addr >= base and addr <= base + len - sz;
}

// load power-of-two bytes from physical address
// will delegate to mmio devices
pub fn load(memory: Memory, comptime T: type, addr: u64) !T {
    const sz = @divExact(@typeInfo(T).int.bits, 8);
    std.debug.assert(addr % sz == 0);
    // ram
    if (access_bounded(addr, sz, mem_base, memory.mem.len)) {
        @branchHint(.likely);
        const offset = addr - mem_base;
        const slice = memory.mem[offset .. offset + sz][0..sz];
        const v = std.mem.readInt(T, slice, .little);
        return v;
    }
    // mmio devices
    for (memory.devices) |dev| {
        if (access_bounded(addr, sz, dev.mmio_base, dev.mmio_len)) {
            const reg_offset = addr - dev.mmio_base;
            return try dev.mmio_reg_read(T, reg_offset);
        }
    }
    // fault
    return error.LoadAccessFault;
}

// store power-of-two bytes at physical address
// will delegate to mmio devices
pub fn store(memory: Memory, comptime T: type, addr: u64, v: T) !void {
    const sz = @divExact(@typeInfo(T).int.bits, 8);
    std.debug.assert(addr % sz == 0);
    // ram
    if (access_bounded(addr, sz, mem_base, memory.mem.len)) {
        @branchHint(.likely);
        const offset = addr - mem_base;
        const slice = memory.mem[offset .. offset + sz][0..sz];
        std.mem.writeInt(T, slice, v, .little);
        return;
    }
    // device mmio
    for (memory.devices) |dev| {
        if (access_bounded(addr, sz, dev.mmio_base, dev.mmio_len)) {
            const reg_offset = addr - dev.mmio_base;
            try dev.mmio_reg_write(T, reg_offset, v);
            return;
        }
    }
    // fault
    return error.StoreAccessFault;
}

// fetch instruction bytes from physical address
// instruction fetch is 4 bytes long
// instruction fetch is not supported from mmio devices
pub fn fetch(memory: Memory, addr: u64) !u32 {
    std.debug.assert(addr % 4 == 0);
    // ram
    if (access_bounded(addr, 4, mem_base, memory.mem.len)) {
        @branchHint(.likely);
        const offset = addr - mem_base;
        const slice = memory.mem[offset .. offset + 4][0..4];
        const v = std.mem.readInt(u32, slice, .little);
        return v;
    }
    // fault
    return error.InstAccessFault;
}
