// Control and Status Registers

const Exception = @import("exception.zig").Exception;
const Privilege = @import("priv.zig").Privilege;
const CLINT = @import("timer.zig");
const xlen = @import("hart.zig").xlen;

const CSRs = @This();

mepc: xlen, // M-mode exception program counter
mtval: xlen, // M-mode trap value
mcause: xlen, // M-mode trap cause
mscratch: xlen, // M-mode scratch register
mtvec: struct { // M-mode trap vector
    base: xlen, // trap vector base address
    vectored: bool, // vectored interrupts
},
mstatus: struct { // M-mode status register
    mie: bool, // M-mode global interrupt enable
    mpie: bool, // M-mode previous interrupt enable
    mpp: Privilege, // previous privilege
},
mie: struct { // M-mode interrupt enable register
    msie: bool, // Software interrupt enable
    mtie: bool, // Timer interrupt enable
    meie: bool, // External interrupt enable
},
mip: struct { // M-mode interrupt pending register
    msip: bool, // Software interrupt pending
    mtip: bool, // Timer interrupt pending
    meip: bool, // External interrupt pending
},

time_csr_timer: *CLINT, // Timer for time CSR

inline fn mstatus_read(csrs: CSRs) xlen {
    // zig fmt: off
    return set_bit(csrs.mstatus.mie, 3)
        | set_bit(csrs.mstatus.mpie, 7)
        | @as(xlen, @intFromEnum(csrs.mstatus.mpp)) << 11;
    // zig fmt: on
}

inline fn mstatus_write(csrs: *CSRs, v: xlen) void {
    // zig fmt: off
    csrs.mstatus.mie = get_bit(v, 3);
    csrs.mstatus.mpie = get_bit(v, 7);
    const mpp: u2 = @truncate((v >> 11) & 0b11);
    // TODO: only M and U modes are supported for now, change this check
    // once S-mode is implemented
    if (mpp == 0b00 or mpp == 0b11) csrs.mstatus.mpp = @enumFromInt(mpp);
}

inline fn mie_read(csrs: CSRs) xlen {
    return set_bit(csrs.mie.msie, 3) | set_bit(csrs.mie.mtie, 7) | set_bit(csrs.mie.meie, 11);
}

inline fn mie_write(csrs: *CSRs, v: xlen) void {
    csrs.mie.msie = get_bit(v, 3);
    csrs.mie.mtie = get_bit(v, 7);
    csrs.mie.meie = get_bit(v, 11);
}

inline fn mip_read(csrs: CSRs) xlen {
    return set_bit(csrs.mip.msip, 3) | set_bit(csrs.mip.mtip, 7) | set_bit(csrs.mip.meip, 11);
}

// CSR numbering
// csrno[9:8] indicates the minimum privilege level required
// to access the corresponding CSR,
// csrno[11:10] = 11 indicates the CSR is read-only
// zig fmt: off
const csr_mstatus    = 0x300;
const csr_misa       = 0x301;
const csr_mie        = 0x304;
const csr_mtvec      = 0x305;
const csr_mscratch   = 0x340;
const csr_mepc       = 0x341;
const csr_mcause     = 0x342;
const csr_mtval      = 0x343;
const csr_mip        = 0x344;
const csr_time       = 0xc01;
const csr_mvendorid  = 0xf11;
const csr_marchid    = 0xf12;
const csr_mimpid     = 0xf13;
const csr_mhartid    = 0xf14;
const csr_mconfigptr = 0xf15;
// zig fmt: on

pub fn init() CSRs {
    return CSRs{
        .mepc = 0,
        .mtval = 0,
        .mcause = 0,
        .mscratch = 0,
        .mtvec = .{
            .base = 0,
            .vectored = false,
        },
        .mstatus = .{
            .mie = false,
            .mpie = false,
            .mpp = .M, // TODO: when U-mode is implemented, set to U
        },
        .mie = .{
            .msie = false,
            .mtie = false,
            .meie = false,
        },
        .mip = .{
            .msip = false,
            .mtip = false,
            .meip = false,
        },
        .time_csr_timer = undefined,
    };
}

inline fn get_bit(v: xlen, bit: u6) bool {
    return ((v >> bit) & 0b1) != 0;
}

inline fn set_bit(v: bool, bit: u6) xlen {
    return @as(xlen, @intFromBool(v)) << bit;
}

// zig fmt: off
const misa_value: xlen = @as(xlen, 0b10) << 62 // xlen=64
    | 0b10000100000001000100000001;
// isa: zyxwvutsrqponmlkjihgfedcba, currently implemented bits: imauz
// // zig fmt: on

const Illegal = Exception.IllegalInstruction;

// read from CSR 'csrno'
pub fn read(csrs: CSRs, csrno: u12, priv: Privilege) Exception!xlen {
    const perm: u2 = @truncate(csrno >> 8);
    if (@intFromEnum(priv) < perm) return Illegal;
    // permission check passed
    return switch (csrno) {
        csr_mstatus => csrs.mstatus_read(),
        csr_misa => misa_value,
        csr_mie => csrs.mie_read(),
        csr_mtvec => csrs.mtvec.base
            | @intFromBool(csrs.mtvec.vectored),
        csr_mscratch => csrs.mscratch,
        csr_mepc => csrs.mepc,
        csr_mcause => csrs.mcause,
        csr_mtval => csrs.mtval,
        csr_mip => csrs.mip_read(),
        csr_time => csrs.time_csr_timer.mtime,
        csr_mvendorid => 0,
        csr_marchid => 0,
        csr_mimpid => 0,
        csr_mhartid => 0,
        csr_mconfigptr => 0,
        else => Illegal,
    };
}

// write to CSR 'csrno'
pub fn write(csrs: *CSRs, csrno: u12, priv: Privilege, v: xlen) Exception!void {
    const perm: u2 = @truncate(csrno >> 8);
    if (@intFromEnum(priv) < perm) return Illegal;
    const rw: u2 = @truncate(csrno >> 10);
    if (rw == 0b11) return Illegal;
    // permission check passed
    switch (csrno) {
        csr_mstatus => csrs.mstatus_write(v),
        csr_misa => {}, // misa is read-only
        csr_mie => csrs.mie_write(v),
        csr_mtvec => csrs.mtvec = .{
            .base = v & ~@as(xlen, 0b11),
            .vectored = (v & 0b11) == 0b01,
        },
        csr_mscratch => csrs.mscratch = v,
        csr_mepc => csrs.mepc = v,
        csr_mcause => csrs.mcause = v,
        csr_mtval => csrs.mtval = v,
        csr_mip => {}, // mip is read-only
        else => return Illegal,
    }
    return;
}

pub fn exception_to_xcause_csr_value(err: Exception) xlen {
    return switch (err) {
        Exception.InstMisaligned => 0,
        Exception.InstAccessFault => 1,
        Exception.IllegalInstruction => 2,
        Exception.Breakpoint => 3,
        Exception.LoadMisaligned => 4,
        Exception.LoadAccessFault => 5,
        Exception.StoreMisaligned => 6,
        Exception.StoreAccessFault => 7,
        Exception.ECallUser => 8,
        Exception.ECallSupervisor => 9,
        Exception.ECallMachine => 11,
        Exception.InstPageFault => 12,
        Exception.LoadPageFault => 13,
        Exception.StorePageFault => 15,
    };
}
