// RISC-V exception and trap types

pub const Exception = error{
    // instruction fetch and execute exceptions
    InstAddrMisaligned,
    InstPageFault,
    InstAccessFault,
    IllegalInstruction,
    // load exceptions
    LoadMisaligned,
    LoadPageFault,
    LoadAccessFault,
    // store exceptions
    StoreMisaligned,
    StorePageFault,
    StoreAccessFault,
    // miscellaneous
    Breakpoint,
    ECallUser,
    ECallSupervisor,
    ECallMachine,
};

pub fn exception_to_xcause_value(err: Exception) u32 {
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
