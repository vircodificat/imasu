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
