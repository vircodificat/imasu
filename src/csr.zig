// Control and Status Registers

const riscv = @import("riscv.zig");
const Exception = riscv.Exception;
const Illegal = Exception.IllegalInstruction;
const Privilege = riscv.Privilege;
const CLINT = @import("devices/clint.zig");
const MMU = @import("mmu.zig");
const xlen = riscv.xlen;

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
    mprv: bool, // Modify privilege
    // sum, mxr are stored in the MMU
    tvm: bool, // Trap Virtual Memory
    tsr: bool, // Trap sret
},
medeleg: [16]bool, // M-mode exception delegation register
mideleg: struct { // M-mode interrupt delegation register
    sti: bool, // S-mode Timer interrupt delegate
    sei: bool, // S-mode External interrupt delegate
},
ie: struct { // Interrupt enable register
    msie: bool, // M-mode Software interrupt enable
    stie: bool, // S-mode Timer interrupt enable
    mtie: bool, // M-mode Timer interrupt enable
    seie: bool, // S-mode External interrupt enable
    meie: bool, // M-mode External interrupt enable
},
ip: struct { // Interrupt pending register
    msip: bool, // M-mode Software interrupt pending
    stip: bool, // S-mode Timer interrupt pending
    mtip: bool, // M-mode Timer interrupt pending
    seip: bool, // S-mode External interrupt pending
    meip: bool, // M-mode External interrupt pending
},
counteren: struct { // Counter-enable registers
    mcy: bool, // M-mode Cycle counter enable
    mtm: bool, // M-mode Timer counter enable
    scy: bool, // S-mode Cycle counter enable
    stm: bool, // S-mode Timer counter enable
},
countinhibit: struct { // Counter inhibit register
    cy: bool, // M-mode inhibit cycle counter
},
cycle: xlen, // Cycles counter for cycle CSR
mmu: *MMU, // MMU for setting/reading MMU settings
time_csr_timer: *CLINT, // Timer for time CSR

inline fn mstatus_read(csrs: CSRs) xlen {
    // zig fmt: off
    return set_bit(csrs.status.sie, 1)
        | set_bit(csrs.status.mie, 3)
        | set_bit(csrs.status.spie, 5)
        | set_bit(csrs.status.mpie, 7)
        | set_bit(csrs.status.spp, 8)
        | @as(xlen, @intFromEnum(csrs.status.mpp)) << 11
        | set_bit(csrs.status.mprv, 17)
        | set_bit(csrs.mmu.sum, 18)
        | set_bit(csrs.mmu.mxr, 19)
        | set_bit(csrs.status.tvm, 20)
        | set_bit(csrs.status.tsr, 22);
    // zig fmt: on
}

inline fn sstatus_read(csrs: CSRs) xlen {
    // zig fmt: off
    return set_bit(csrs.status.sie, 1)
        | set_bit(csrs.status.spie, 5)
        | set_bit(csrs.status.spp, 8)
        | set_bit(csrs.mmu.sum, 18)
        | set_bit(csrs.mmu.mxr, 19);
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
    csrs.status.mprv = get_bit(v, 17);
    csrs.mmu.sum = get_bit(v, 18);
    csrs.mmu.mxr = get_bit(v, 19);
    csrs.status.tvm = get_bit(v, 20);
    csrs.status.tsr = get_bit(v, 22);
}

inline fn sstatus_write(csrs: *CSRs, v: xlen) void {
    csrs.status.sie = get_bit(v, 1);
    csrs.status.spie = get_bit(v, 5);
    csrs.status.spp = get_bit(v, 8);
    csrs.mmu.sum = get_bit(v, 18);
    csrs.mmu.mxr = get_bit(v, 19);
}

inline fn medeleg_read(csrs: CSRs) xlen {
    var v: xlen = 0;
    for (csrs.medeleg, 0..) |deleg, idx| {
        v |= set_bit(deleg, @truncate(idx));
    }
    return v;
}

inline fn medeleg_write(csrs: *CSRs, v: xlen) void {
    for (0..16) |idx| {
        if (idx == 10 or idx == 14) continue;
        csrs.medeleg[idx] = get_bit(v, @truncate(idx));
    }
}

inline fn mideleg_read(csrs: CSRs) xlen {
    return set_bit(csrs.mideleg.sti, 5) | set_bit(csrs.mideleg.sei, 9);
}

inline fn mideleg_write(csrs: *CSRs, v: xlen) void {
    csrs.mideleg.sti = get_bit(v, 5);
    csrs.mideleg.sei = get_bit(v, 9);
}

inline fn mie_read(csrs: CSRs) xlen {
    // zig fmt: off
    return set_bit(csrs.ie.msie, 3)
        | set_bit(csrs.ie.stie, 5)
        | set_bit(csrs.ie.mtie, 7)
        | set_bit(csrs.ie.seie, 9)
        | set_bit(csrs.ie.meie, 11);
    // zig fmt: on
}

inline fn sie_read(csrs: CSRs) xlen {
    // interrupts in sie/sip are only readable if they have been delegated
    // zig fmt: off
    return set_bit(csrs.ie.stie and csrs.mideleg.sti, 5)
        | set_bit(csrs.ie.seie and csrs.mideleg.sei, 9);
    // zig fmt: on
}

inline fn mie_write(csrs: *CSRs, v: xlen) void {
    csrs.ie.msie = get_bit(v, 3);
    csrs.ie.stie = get_bit(v, 5);
    csrs.ie.mtie = get_bit(v, 7);
    csrs.ie.seie = get_bit(v, 9);
    csrs.ie.meie = get_bit(v, 11);
}

inline fn sie_write(csrs: *CSRs, v: xlen) void {
    // interrupts in sie are only writable if they have been delegated
    if (csrs.mideleg.sti) csrs.ie.stie = get_bit(v, 5);
    if (csrs.mideleg.sei) csrs.ie.seie = get_bit(v, 9);
}

inline fn mip_read(csrs: CSRs) xlen {
    // zig fmt: off
    return set_bit(csrs.ip.msip, 3)
        | set_bit(csrs.ip.stip, 5)
        | set_bit(csrs.ip.mtip, 7)
        | set_bit(csrs.ip.seip, 9)
        | set_bit(csrs.ip.meip, 11);
    // zig fmt: on
}

inline fn mip_write(csrs: *CSRs, v: xlen) void {
    // S-mode interrupt bits are writable in mip,
    // sip itself is read-only
    csrs.ip.stip = get_bit(v, 5);
    csrs.ip.seip = get_bit(v, 9);
}

inline fn sip_read(csrs: CSRs) xlen {
    // interrupts in sie/sip are only readabe if they have been delegated
    // zig fmt: off
    return set_bit(csrs.mideleg.sti and csrs.ip.stip, 5)
        | set_bit(csrs.mideleg.sei and csrs.ip.seip, 9);
    // zig fmt: on
}

inline fn satp_read(csrs: CSRs) xlen {
    const mode: xlen = switch (csrs.mmu.mode) {
        .Bare => 0,
        .Sv39 => 8,
    };
    return csrs.mmu.ppn | mode << 60;
}

inline fn satp_write(csrs: *CSRs, v: xlen) void {
    // the entire write to satp has no effect if mode is not supported
    const mode: u4 = @truncate(v >> 60);
    csrs.mmu.mode = switch (mode) {
        0 => .Bare,
        8 => .Sv39,
        else => return,
    };
    csrs.mmu.ppn = v & 0xfff_ffff_ffff;
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
const csr_cycle         = 0xc00;
const csr_time          = 0xc01;
const csr_mvendorid     = 0xf11;
const csr_marchid       = 0xf12;
const csr_mimpid        = 0xf13;
const csr_mhartid       = 0xf14;
const csr_mconfigptr    = 0xf15;
// zig fmt: on

// for the purposes of interrupt checking on csr write
// see sections "machine interrupt registers (mip and mie)"
// and "supervisor interrupt registers (sip and sie)" in
// the privileged spec
pub fn is_interrupt_related(csrno: u12) bool {
    return switch (csrno) {
        csr_mip,
        csr_mie,
        csr_mstatus,
        csr_mideleg,
        csr_sip,
        csr_sie,
        csr_sstatus,
        => true,
        else => false,
    };
}

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
            .mprv = false,
            .tvm = false,
            .tsr = false,
        },
        .medeleg = .{false} ** 16,
        .mideleg = .{
            .sti = false,
            .sei = false,
        },
        .ie = .{
            .msie = false,
            .stie = false,
            .mtie = false,
            .seie = false,
            .meie = false,
        },
        .ip = .{
            .msip = false,
            .stip = false,
            .mtip = false,
            .seip = false,
            .meip = false,
        },
        .counteren = .{
            .mcy = true,
            .scy = true,
            .mtm = true,
            .stm = true,
        },
        .countinhibit = .{ .cy = false },
        .cycle = 0,
        .mmu = undefined,
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
    | 0b10000101000001000100000001; // imasuz
// isa: zyxwvutsrqponmlkjihgfedcba
// // zig fmt: on

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
        csr_scounteren => set_bit(csrs.counteren.scy, 0)
            | set_bit(csrs.counteren.stm, 1),
        csr_sscratch => csrs.sscratch,
        csr_sepc => csrs.sepc,
        csr_scause => csrs.scause,
        csr_stval => csrs.stval,
        csr_sip => csrs.sip_read(),
        csr_satp => if (csrs.status.tvm) Illegal else csrs.satp_read(),
        csr_mstatus => csrs.mstatus_read(),
        csr_misa => misa_value,
        csr_medeleg => csrs.medeleg_read(),
        csr_mideleg => csrs.mideleg_read(),
        csr_mie => csrs.mie_read(),
        csr_mtvec => csrs.mtvec.base
            | @intFromBool(csrs.mtvec.vectored),
        csr_mcounteren => set_bit(csrs.counteren.mcy, 0)
            | set_bit(csrs.counteren.mtm, 1),
        csr_menvcfg => 0, // we do not implement any of menvcfg
        csr_mcountinhibit => set_bit(csrs.countinhibit.cy, 0),
        csr_mscratch => csrs.mscratch,
        csr_mepc => csrs.mepc,
        csr_mcause => csrs.mcause,
        csr_mtval => csrs.mtval,
        csr_mip => csrs.mip_read(),
        csr_cycle => {
            const access = switch (priv) {
                .M => true,
                .S => csrs.counteren.mcy,
                .U => csrs.counteren.mcy and csrs.counteren.scy,
            };
            if (!access) return Illegal;
            return csrs.cycle;
        },
        csr_time => {
            const access = switch (priv) {
                .M => true,
                .S => csrs.counteren.mtm,
                .U => csrs.counteren.mtm and csrs.counteren.stm,
            };
            if (!access) return Illegal;
            return CLINT.system_mtime();
        },
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
        csr_scounteren => {
            csrs.counteren.scy = get_bit(v, 0);
            csrs.counteren.stm = get_bit(v, 1);
        },
        csr_sscratch => csrs.sscratch = v,
        csr_sepc => csrs.sepc = v,
        csr_scause => csrs.scause = v,
        csr_stval => csrs.stval = v,
        csr_sip =>  {}, // sip is read-only
        csr_satp => if (csrs.status.tvm)
            return Illegal else csrs.satp_write(v),
        csr_mstatus => csrs.mstatus_write(v),
        csr_misa => {}, // misa is read-only
        csr_medeleg => csrs.medeleg_write(v),
        csr_mideleg => csrs.mideleg_write(v),
        csr_mie => csrs.mie_write(v),
        csr_mtvec => csrs.mtvec = .{
            .base = v & ~@as(xlen, 0b11),
            .vectored = (v & 0b11) == 0b01,
        },
        csr_mcounteren => {
            csrs.counteren.mcy = get_bit(v, 0);
            csrs.counteren.mtm = get_bit(v, 1);
        },
        csr_menvcfg => {}, // we do not implement any of menvcfg
        csr_mcountinhibit => csrs.countinhibit = .{ .cy = get_bit(v, 0) },
        csr_mscratch => csrs.mscratch = v,
        csr_mepc => csrs.mepc = v,
        csr_mcause => csrs.mcause = v,
        csr_mtval => csrs.mtval = v,
        csr_mip => csrs.mip_write(v),
        else => return Illegal,
    }
}
