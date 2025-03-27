// Control and Status Registers

const Exception = @import("exception.zig").Exception;
const Privilege = @import("priv.zig").Privilege;
const CLINT = @import("devices/clint.zig");
const xlen = @import("hart.zig").xlen;

const CSRs = @This();

sepc: xlen, // S-mode exception program counter
stval: xlen, // S-mode trap value
scause: xlen, // S-mode trap cause
sscratch: xlen, // S-mode scratch register
stvec: struct { // S-mode trap vector
    base: xlen, // trap vector base address
    vectored: bool, // vectored interrupts
},
mepc: xlen, // M-mode exception program counter
mtval: xlen, // M-mode trap value
mcause: xlen, // M-mode trap cause
mscratch: xlen, // M-mode scratch register
mtvec: struct { // M-mode trap vector
    base: xlen, // trap vector base address
    vectored: bool, // vectored interrupts
},
status: struct { // status register
    sie: bool, // S-mode global interrupt enable
    mie: bool, // M-mode global interrupt enable
    spie: bool, // S-mode previous interrupt enable
    mpie: bool, // M-mode previous interrupt enable
    spp: bool, // S-mode previous privilege
    mpp: Privilege, // M-mode previous privilege
},
ie: struct { // Interrupt enable register
    msie: bool, // M-mode Software interrupt enable
    mtie: bool, // M-mode Timer interrupt enable
    meie: bool, // M-mode External interrupt enable
},
ip: struct { // Interrupt pending register
    msip: bool, // M-mode Software interrupt pending
    mtip: bool, // M-mode Timer interrupt pending
    meip: bool, // M-mode External interrupt pending
},

time_csr_timer: *CLINT, // Timer for time CSR

inline fn mstatus_read(csrs: CSRs) xlen {
    // zig fmt: off
    return set_bit(csrs.status.sie, 1)
        | set_bit(csrs.status.mie, 3)
        | set_bit(csrs.status.spie, 5)
        | set_bit(csrs.status.mpie, 7)
        | set_bit(csrs.status.spp, 8)
        | @as(xlen, @intFromEnum(csrs.status.mpp)) << 11;
    // zig fmt: on
}

inline fn sstatus_read(csrs: CSRs) xlen {
    // zig fmt: off
    return set_bit(csrs.status.sie, 1)
        | set_bit(csrs.status.spie, 5)
        | set_bit(csrs.status.spp, 8);
    // zig fmt: on
}

inline fn mstatus_write(csrs: *CSRs, v: xlen) void {
    csrs.status.sie = get_bit(v, 1);
    csrs.status.mie = get_bit(v, 3);
    csrs.status.spie = get_bit(v, 5);
    csrs.status.mpie = get_bit(v, 7);
    csrs.status.spp = get_bit(v, 8);
    const mpp: u2 = @truncate((v >> 11) & 0b11);
    if (mpp != 0b10) csrs.status.mpp = @enumFromInt(mpp);
}

inline fn sstatus_write(csrs: *CSRs, v: xlen) void {
    csrs.status.sie = get_bit(v, 1);
    csrs.status.spie = get_bit(v, 5);
    csrs.status.spp = get_bit(v, 8);
}

inline fn mie_read(csrs: CSRs) xlen {
    return set_bit(csrs.ie.msie, 3) | set_bit(csrs.ie.mtie, 7) | set_bit(csrs.ie.meie, 11);
}

inline fn sie_read(csrs: CSRs) xlen {
    _ = csrs;
    return 0; // TODO: do we support supervisor interrupts?
}

inline fn mie_write(csrs: *CSRs, v: xlen) void {
    csrs.ie.msie = get_bit(v, 3);
    csrs.ie.mtie = get_bit(v, 7);
    csrs.ie.meie = get_bit(v, 11);
}

inline fn sie_write(csrs: *CSRs, v: xlen) void {
    _ = csrs;
    _ = v;
    // TODO: do we support supervisor interrupts?
}

inline fn mip_read(csrs: CSRs) xlen {
    return set_bit(csrs.ip.msip, 3) | set_bit(csrs.ip.mtip, 7) | set_bit(csrs.ip.meip, 11);
}

inline fn sip_read(csrs: CSRs) xlen {
    _ = csrs;
    return 0; // TODO: do we support supervisor interrupts?
}

// CSR numbering
// csrno[9:8] indicates the minimum privilege level required
// to access the corresponding CSR,
// csrno[11:10] = 11 indicates the CSR is read-only
// zig fmt: off
const csr_sstatus       = 0x100;
const csr_sie           = 0x104;
const csr_stvec         = 0x105;
const csr_scounteren    = 0x106;
const csr_sscratch      = 0x140;
const csr_sepc          = 0x141;
const csr_scause        = 0x142;
const csr_stval         = 0x143;
const csr_sip           = 0x144;
const csr_satp          = 0x180;
const csr_mstatus       = 0x300;
const csr_misa          = 0x301;
const csr_medeleg       = 0x302;
const csr_mideleg       = 0x303;
const csr_mie           = 0x304;
const csr_mtvec         = 0x305;
const csr_mcounteren    = 0x306;
const csr_menvcfg       = 0x30a;
const csr_mcountinhibit = 0x320;
const csr_mscratch      = 0x340;
const csr_mepc          = 0x341;
const csr_mcause        = 0x342;
const csr_mtval         = 0x343;
const csr_mip           = 0x344;
const csr_time          = 0xc01;
const csr_mvendorid     = 0xf11;
const csr_marchid       = 0xf12;
const csr_mimpid        = 0xf13;
const csr_mhartid       = 0xf14;
const csr_mconfigptr    = 0xf15;
// zig fmt: on

pub fn create() CSRs {
    return CSRs{
        .sepc = 0,
        .stval = 0,
        .scause = 0,
        .sscratch = 0,
        .stvec = .{
            .base = 0,
            .vectored = false,
        },
        .mepc = 0,
        .mtval = 0,
        .mcause = 0,
        .mscratch = 0,
        .mtvec = .{
            .base = 0,
            .vectored = false,
        },
        .status = .{
            .sie = false,
            .mie = false,
            .spie = false,
            .mpie = false,
            .spp = false,
            .mpp = .U,
        },
        .ie = .{
            .msie = false,
            .mtie = false,
            .meie = false,
        },
        .ip = .{
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
    | 0b10000101000001000100000001;
// isa: zyxwvutsrqponmlkjihgfedcba, currently implemented bits: imasuz
// // zig fmt: on

const Illegal = Exception.IllegalInstruction;

// read from CSR 'csrno'
pub fn read(csrs: CSRs, csrno: u12, priv: Privilege) Exception!xlen {
    const perm: u2 = @truncate(csrno >> 8);
    if (@intFromEnum(priv) < perm) return Illegal;
    // permission check passed
    return switch (csrno) {
        csr_sstatus => csrs.sstatus_read(),
        csr_sie => csrs.sie_read(),
        csr_stvec => csrs.stvec.base
        | @intFromBool(csrs.stvec.vectored),
        csr_scounteren => 0, // TODO: should be a single bit for time
        csr_sscratch => csrs.sscratch,
        csr_sepc => csrs.sepc,
        csr_scause => csrs.scause,
        csr_stval => csrs.stval,
        csr_sip => csrs.sip_read(),
        csr_satp => 0, // TODO: no address translation (Bare) for now
        csr_mstatus => csrs.mstatus_read(),
        csr_misa => misa_value,
        csr_medeleg => 0, // TODO: does not support delegation for now
        csr_mideleg => 0, // TODO: does not support delegation for now
        csr_mie => csrs.mie_read(),
        csr_mtvec => csrs.mtvec.base
            | @intFromBool(csrs.mtvec.vectored),
        csr_mcounteren => return 0, // TODO
        csr_menvcfg => 0, // TODO
        csr_mcountinhibit => 0, // TODO
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
        csr_sstatus => csrs.sstatus_write(v),
        csr_sie => csrs.sie_write(v),
        csr_stvec => csrs.stvec = .{
            .base = v & ~@as(xlen, 0b11),
            .vectored = (v & 0b11) == 0b01,
        },
        csr_scounteren => {}, // TODO
        csr_sscratch => csrs.sscratch = v,
        csr_sepc => csrs.sepc = v,
        csr_scause => csrs.scause = v,
        csr_stval => csrs.stval = v,
        csr_sip =>  {}, // sip is read-only
        csr_satp => {}, // TODO: no address translation (Bare) for now
        csr_mstatus => csrs.mstatus_write(v),
        csr_misa => {}, // misa is read-only
        csr_medeleg => {}, // TODO: does not support delegation for now
        csr_mideleg => {}, // TODO: does not support delegation for now
        csr_mie => csrs.mie_write(v),
        csr_mtvec => csrs.mtvec = .{
            .base = v & ~@as(xlen, 0b11),
            .vectored = (v & 0b11) == 0b01,
        },
        csr_mcounteren => {}, // TODO
        csr_menvcfg => {}, // TODO
        csr_mcountinhibit => {}, // TODO
        csr_mscratch => csrs.mscratch = v,
        csr_mepc => csrs.mepc = v,
        csr_mcause => csrs.mcause = v,
        csr_mtval => csrs.mtval = v,
        csr_mip => {}, // mip is read-only
        else => return Illegal,
    }
    return;
}
