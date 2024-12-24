pub const Privilege = enum(u2) {
    U = 0b00, // User mode
    S = 0b01, // Supervisor mode
    M = 0b11, // Machine mode
};
