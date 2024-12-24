// Interfaces to physical memory

const std = @import("std");

pub const Memory = struct {
    mem: []u8, // ram
    // TODO: device mmio

    pub const mem_base: u64 = 0x8000_0000; // lowest address of ram

    pub fn init(mem: []u8) Memory {
        std.debug.assert(mem.len % 4096 == 0);
        return Memory{ .mem = mem };
    }

    // return whether [addr,addr+sz) lies within [base,base+len]
    inline fn access_bounded(addr: u64, sz: u64, base: u64, len: u64) bool {
        return addr >= base and addr <= base + len - sz;
    }

    // internal load power-of-two bytes from address, as regular load or instruction fetch
    fn load(memory: Memory, comptime T: type, addr: u64, comptime inst_fetch: bool) !T {
        const sz = @divExact(@typeInfo(T).int.bits, 8);
        if (comptime !std.math.isPowerOfTwo(sz) or @typeInfo(T).int.signedness == .signed) {
            @compileError("Memory access must be a power of two number of bytes");
        }
        if (comptime inst_fetch and sz != 4) {
            @compileError("Instruction fetch must be exactly 4-bytes");
        }
        if (addr % sz != 0) return if (comptime inst_fetch) error.InstMisaligned else error.LoadMisaligned;
        if (access_bounded(addr, sz, memory.mem_base, memory.mem.len)) {
            const offset = addr - memory.mem_base;
            const v = std.mem.readInt(T, memory.mem[offset .. offset + sz][0..sz], .little);
            return v;
        }
        return if (comptime inst_fetch) error.InstAccessFault else error.LoadAccessFault;
    }

    // internal store power-of-two bytes at address
    fn store(memory: Memory, comptime T: type, addr: u64, v: T) !void {
        const sz = @divExact(@typeInfo(T).int.bits, 8);
        if (comptime !std.math.isPowerOfTwo(sz) or @typeInfo(T).int.signedness == .signed) {
            @compileError("Memory access must be a power of two number of bytes");
        }
        if (addr % sz != 0) return error.StoreMisaligned;
        if (access_bounded(addr, sz, memory.mem_base, memory.mem.len)) {
            const offset = addr - memory.mem_base;
            std.mem.writeInt(T, memory.mem[offset .. offset + sz][0..sz], v, .little);
            return;
        }
        return error.StoreAccessFault;
    }

    // public load/fetch/store instructions
    pub fn load_byte(memory: Memory, addr: u64) !u8 {
        return memory.load(u8, addr, false);
    }
    pub fn load_half(memory: Memory, addr: u64) !u16 {
        return memory.load(u16, addr, false);
    }
    pub fn load_word(memory: Memory, addr: u64) !u32 {
        return memory.load(u32, addr, false);
    }
    pub fn load_double(memory: Memory, addr: u64) !u64 {
        return memory.load(u64, addr, false);
    }
    pub fn fetch_instruction(memory: Memory, addr: u64) !u32 {
        return memory.load(u32, addr, true);
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
};
