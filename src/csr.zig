// Control and Status Registers

const Exception = @import("exception.zig").Exception;
const Privilege = @import("priv.zig").Privilege;
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

inline fn mstatus_read(csrs: CSRs) xlen {
    // zig fmt: off
    return set_bit(csrs.mstatus.mie, 3)
        | set_bit(csrs.mstatus.mpie, 7)
        | @as(xlen, @intFromEnum(csrs.mstatus.mpp)) << 11;
    // zig fmt: on
}

inline fn mstatus_write(csrs: CSRs, v: xlen) void {
    // zig fmt: off
    csrs.mstatus.mie = get_bit(v, 3);
    csrs.mstatus.mpie = get_bit(v, 7);
    const mpp: u2 = @truncate((v >> 11) & 0b11);
    // TODO: only M-mode is supported for now, change this check
    // once U-mode and S-mode are implemented
    if (mpp == 0b11) csrs.mstatus.mpp = .M;
}

// CSR numbering
// csrno[9:8] indicates the minimum privilege level required
// to access the corresponding CSR,
// csrno[11:10] = 11 indicates the CSR is read-only
const csrnos = enum(u12) {
    // zig fmt: off
    mstatus  = 0x300,
    misa     = 0x301,
    mtvec    = 0x305,
    mscratch = 0x340,
    mepc     = 0x341,
    mcause   = 0x342,
    mtval    = 0x343,
    // zig fmt: on
};

// zig fmt: off
const misa_value: xlen = @as(xlen, 0b10) << 62 // xlen=64
    | 0b10000000000000000100000000;
// isa: zyxwvutsrqponmlkjihgfedcba
// // zig fmt: on

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
    };
}

// read from CSR 'csrno'
pub fn read(csrs: CSRs, csrno: u12, priv: Privilege) !xlen {
    const perm: u2 = @truncate(csrno >> 8);
    if (@intFromEnum(priv) < perm) return Exception.IllegalInstruction;
    // permission check passed
    return switch (csrno) {
        csrnos.mstatus => csrs.mstatus_read(),
        csrnos.misa => misa_value,
        csrnos.mtvec => csrs.mtvec.base | @intFromBool(csrs.mtvec.vectored),
        csrnos.mscratch => csrs.mscratch,
        csrnos.mepc => csrs.mepc,
        csrnos.mcause => csrs.mcause,
        csrnos.mtval => csrs.mtval,
        else => Exception.IllegalInstruction,
    };
}

// write to CSR 'csrno'
pub fn write(csrs: *CSRs, csrno: u12, v: xlen, priv: Privilege) !void {
    const perm: u2 = @truncate(csrno >> 8);
    if (@intFromEnum(priv) < perm) return Exception.IllegalInstruction;
    const rw: u2 = @truncate(csrno >> 10);
    if (rw == 0b11) return Exception.IllegalInstruction;
    // permission check passed
    switch (csrno) {
        csrnos.mstatus => csrs.mstatus_write(v),
        csrnos.misa => {},
        csrnos.mtvec => csrs.mtvec = .{
            .base = v & ~@as(xlen, 0b11),
            .vectored = (v & 0b11) == 0b01,
        },
        csrnos.mscratch => csrs.mscratch = v,
        csrnos.mepc => csrs.mepc = v,
        csrnos.mcause => csrs.mcause = v,
        csrnos.mtval => csrs.mtval = v,
        else => return Exception.IllegalInstruction,
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

inline fn get_bit(v: xlen, bit: u6) bool {
    return ((v >> bit) & 0b1) != 0;
}

inline fn set_bit(v: bool, bit: u6) xlen {
    return @as(xlen, @intFromBool(v)) << bit;
}
