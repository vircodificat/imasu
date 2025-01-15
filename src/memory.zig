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

// fetch instruction bytes from address
// instruction fetch is 4 bytes long
// instruction fetch is not supported from mmio devices
pub fn fetch(memory: Memory, addr: u64) !u32 {
    // check alignment
    if (addr % 4 != 0) return error.InstMisaligned;
    // ram
    if (access_bounded(addr, 4, mem_base, memory.mem.len)) {
        const offset = addr - mem_base;
        const v = std.mem.readInt(u32, memory.mem[offset .. offset + 4][0..4], .little);
        return v;
    }
    // fault
    return error.LoadAccessFault;
}

// load power-of-two bytes from address
// will delegate to mmio devices
fn load(memory: Memory, comptime T: type, addr: u64) !T {
    const sz = @divExact(@typeInfo(T).int.bits, 8);
    if (comptime !std.math.isPowerOfTwo(sz) or @typeInfo(T).int.signedness == .signed) {
        @compileError("Memory access must be a power of two number of bytes");
    }

    // check alignment
    if (addr % sz != 0) return error.LoadMisaligned;

    // ram
    if (access_bounded(addr, sz, mem_base, memory.mem.len)) {
        const offset = addr - mem_base;
        const v = std.mem.readInt(T, memory.mem[offset .. offset + sz][0..sz], .little);
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

// store power-of-two bytes at address
// will delegate to mmio devices
fn store(memory: Memory, comptime T: type, addr: u64, v: T) !void {
    const sz = @divExact(@typeInfo(T).int.bits, 8);
    if (comptime !std.math.isPowerOfTwo(sz) or @typeInfo(T).int.signedness == .signed) {
        @compileError("Memory access must be a power of two number of bytes");
    }

    // check alignment
    if (addr % sz != 0) return error.StoreMisaligned;

    // ram
    if (access_bounded(addr, sz, mem_base, memory.mem.len)) {
        const offset = addr - mem_base;
        std.mem.writeInt(T, memory.mem[offset .. offset + sz][0..sz], v, .little);
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

// public interface for loads/stores

pub fn load_byte(memory: Memory, addr: u64) !u8 {
    return memory.load(u8, addr);
}
pub fn load_half(memory: Memory, addr: u64) !u16 {
    return memory.load(u16, addr);
}
pub fn load_word(memory: Memory, addr: u64) !u32 {
    return memory.load(u32, addr);
}
pub fn load_double(memory: Memory, addr: u64) !u64 {
    return memory.load(u64, addr);
}
pub fn store_byte(memory: Memory, addr: u64, v: u8) !void {
    return memory.store(u8, addr, v);
}
pub fn store_half(memory: Memory, addr: u64, v: u16) !void {
    return memory.store(u16, addr, v);
}
pub fn store_word(memory: Memory, addr: u64, v: u32) !void {
    return memory.store(u32, addr, v);
}
pub fn store_double(memory: Memory, addr: u64, v: u64) !void {
    return memory.store(u64, addr, v);
}
