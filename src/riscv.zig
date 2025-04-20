// common RISC-V definitions and structures

const std = @import("std");

// integer register width
pub const xlen = u64;

// lower word of register
pub inline fn word(v: xlen) u32 {
    return @truncate(v);
}

// cast to unsigned
pub inline fn unsigned(
    value: anytype,
) std.meta.Int(.unsigned, @typeInfo(@TypeOf(value)).int.bits) {
    return @bitCast(value);
}

// cast to signed
pub inline fn signed(
    value: anytype,
) std.meta.Int(.signed, @typeInfo(@TypeOf(value)).int.bits) {
    return @bitCast(value);
}

// zero-extend to xlen
pub inline fn zext_to_xlen(value: anytype) xlen {
    const v = unsigned(value);
    return @as(xlen, v);
}
// sign-extend to xlen
pub inline fn sext_to_xlen(value: anytype) xlen {
    const signed_xlen = std.meta.Int(.signed, @typeInfo(xlen).int.bits);
    return @bitCast(@as(signed_xlen, signed(value)));
}

pub const Privilege = enum(u2) {
    U = 0b00, // User mode
    S = 0b01, // Supervisor mode
    M = 0b11, // Machine mode
};

pub const Exception = error{
    InstMisaligned, // instruction address misaligned
    InstPageFault, // page fault on instruction fetch
    InstAccessFault, // access fault on instruction fetch
    IllegalInstruction, // failed to decode instruction or insufficient priv
    LoadMisaligned, // load address misaligned
    LoadPageFault, // page fault on load
    LoadAccessFault, // access fault on load
    StoreMisaligned, // store address misaligned
    StorePageFault, // page fault on store
    StoreAccessFault, // access fault on store
    Breakpoint, // `ebreak` instruction
    ECallUser, // `ecall` from U-mode
    ECallSupervisor, // `ecall` from S-mode
    ECallMachine, // `ecall` from M-mode
};

// exception to trap cause value
pub fn exception_cause_value(err: Exception) xlen {
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

// interrupt types and trap cause values
pub const Interrupt = enum(xlen) {
    MachineSoftware = 3, // M-mode software interrupt
    SupervisorTimer = 5, // S-mode timer interrupt
    MachineTimer = 7, // M-mode timer interrupt
    SupervisorExternal = 9, // S-mode external interrupt
    MachineExternal = 11, // M-mode external interrupt
};
