// Sv39 Memory-management unit

const Memory = @import("memory.zig");
const Privilege = @import("priv.zig").Privilege;
const xlen = @import("hart.zig").xlen;
const std = @import("std");

const MMU = @This();

mem: *Memory, // handle to physical memory
mode: enum { // translation mode
    Bare,
    Sv39,
},
ppn: u64, // root physical page number
sum: bool, // whether S-mode has access to U-mode memory
mxr: bool, // executable implies readable

pub fn create(mem: *Memory) MMU {
    return MMU{
        .mem = mem,
        .mode = .Bare,
        .ppn = 0,
        .sum = false,
        .mxr = false,
    };
}

const Access = enum { R, W, X };

// translate virtual address to physical address,
// performing a page-table walk if memory translation is active
fn translate(mmu: MMU, vaddr: xlen, priv: Privilege, access: Access) ?u64 {
    // no translation in M-mode or in Bare MMU mode
    if (priv == .M or mmu.mode == .Bare) return vaddr;

    // in Sv39 mode, bits 63-39 must be the same as 38
    if (vaddr != sext_to_xlen(@as(u39, @truncate(vaddr)))) return null;

    const page_size = 4096;
    const pte_size = 8;
    const levels = 3;
    const vpn: [levels]xlen = .{
        (vaddr >> 12) & 0x1ff,
        (vaddr >> 21) & 0x1ff,
        (vaddr >> 30) & 0x1ff,
    };

    // perform page-table walk
    var page_table_paddr = mmu.ppn *% page_size;
    var i: usize = 0;
    for (1..levels + 1) |l| {
        i = levels - l; // i = levels-1 ... 0
        const pte_paddr = page_table_paddr +% (vpn[i] *% pte_size);
        const pte = mmu.mem.load(u64, pte_paddr) catch return null;

        if (!get_bit(pte, 0)) return null; // not a valid PTE

        const r = get_bit(pte, 1);
        const w = get_bit(pte, 2);
        const x = get_bit(pte, 3);
        if (w and !r) return null; // W should imply R

        if (r or x) { // leaf PTE
            const u = get_bit(pte, 4); // whether the page is accessible by U-mode

            const access_ok = switch (priv) {
                .M => unreachable,
                // S-mode can only access U-mode pages if SUM is set
                .S => !u or (u and mmu.sum),
                // U-mode can only access U-mode pages
                .U => u,
            } and switch (access) {
                // if MXR is set, executable pages are also readable
                .R => r or (x and mmu.mxr),
                .W => w,
                .X => x,
            };

            if (!access_ok) return null;

            // check if misaligned superpage
            const pte_ppn = (pte >> 10) & 0xfff_ffff_ffff;
            if (i > 0 and pte_ppn & 0x1ff != 0) return null;
            if (i > 1 and (pte_ppn >> 9) & 0x1ff != 0) return null;

            // check accessed and dirty bits
            const a = get_bit(pte, 6);
            const d = get_bit(pte, 7);
            if (!a or (access == .W and !d)) return null;

            // success
            const paddr_ppn0 = if (i > 0) vpn[0] else (pte >> 10) & 0x1ff;
            const paddr_ppn1 = if (i > 1) vpn[1] else (pte >> 19) & 0x1ff;
            const paddr_ppn2 = (pte >> 28) & 0x3ff_ffff;

            const paddr = (vaddr & 0xfff) // page offset is untranslated
                | paddr_ppn0 << 12 | paddr_ppn1 << 21 | paddr_ppn2 << 30;

            return paddr;
        }

        std.debug.assert(!(r or w or x));
        // not a leaf PTE, continue to another level
        const pte_ppn = (pte >> 10) & 0xfff_ffff_ffff;
        page_table_paddr = pte_ppn *% page_size;
        continue;
    }
    // out of levels
    return null;
}

// load power-of-two bytes at virtual address
pub fn load(
    mmu: MMU,
    comptime T: type,
    vaddr: xlen,
    priv: Privilege,
) !T {
    const sz = @divExact(@typeInfo(T).int.bits, 8);
    if (comptime !std.math.isPowerOfTwo(sz)) {
        @compileError("Memory access must be a power of two number of bytes");
    }
    if (comptime @typeInfo(T).int.signedness == .signed) {
        @compileError("Memory access type must be signed");
    }

    // check alignment
    if (vaddr % sz != 0) {
        @branchHint(.unlikely);
        return error.LoadMisaligned;
    }

    const paddr = mmu.translate(vaddr, priv, .R) // translate
        orelse return error.LoadPageFault;
    return try mmu.mem.load(T, paddr); // perform load
}

// store power-of-two bytes at virtual address
pub fn store(
    mmu: MMU,
    comptime T: type,
    vaddr: xlen,
    v: T,
    priv: Privilege,
) !void {
    const sz = @divExact(@typeInfo(T).int.bits, 8);
    if (comptime !std.math.isPowerOfTwo(sz)) {
        @compileError("Memory access must be a power of two number of bytes");
    }
    if (comptime @typeInfo(T).int.signedness == .signed) {
        @compileError("Memory access type must be signed");
    }

    // check alignment
    if (vaddr % sz != 0) {
        @branchHint(.unlikely);
        return error.StoreMisaligned;
    }

    const paddr = mmu.translate(vaddr, priv, .W) // translate
        orelse return error.StorePageFault;
    return try mmu.mem.store(T, paddr, v); // perform store
}

// fetch instruction at virtual address
// instruction fetch is 4 bytes long
pub fn fetch(mmu: MMU, vaddr: xlen, priv: Privilege) !u32 {
    // check alignment
    if (vaddr % 4 != 0) {
        @branchHint(.cold);
        return error.InstMisaligned;
    }

    const paddr = mmu.translate(vaddr, priv, .X) // translate
        orelse return error.InstPageFault;
    return try mmu.mem.fetch(paddr); // perform fetch
}

inline fn get_bit(v: u64, bit: u6) bool {
    return ((v >> bit) & 0b1) != 0;
}

// cast to signed
inline fn signed(value: anytype) std.meta.Int(.signed, @typeInfo(@TypeOf(value)).int.bits) {
    return @bitCast(value);
}

// sign-extend to xlen
inline fn sext_to_xlen(value: anytype) xlen {
    const signed_xlen = std.meta.Int(.signed, @typeInfo(xlen).int.bits);
    return @bitCast(@as(signed_xlen, signed(value)));
}
