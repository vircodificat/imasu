// RISC-V exception and trap types

pub const Exception = error{
    // instruction fetch and execute exceptions
    InstMisaligned,
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
