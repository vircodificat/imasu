// System controller (Syscon) device
// https://www.kernel.org/doc/Documentation/devicetree/bindings/mfd/syscon.yaml

// this device only implements powering off the system, see the devicetree source
// https://www.kernel.org/doc/Documentation/devicetree/bindings/power/reset/syscon-poweroff.txt

const riscv = @import("../riscv.zig");
const std = @import("std");

const Syscon = @This();

// In actuality the size of the memory region is 4 bytes,
// but OpenSBI domain memory regions must be at least 8 bytes long
pub const mmio_len = 0x8;

pub const poweroff: u32 = 0x0000DEAD;

pub fn mmio_reg_read(_: *Syscon, comptime T: type, reg_addr: u64) ?T {
    if (T != u32 or reg_addr != 0) return null;
    return 0;
}

pub fn mmio_reg_write(_: *Syscon, comptime T: type, reg_addr: u64, v: T) ?void {
    if (T != u32 or reg_addr != 0) return null;
    if (v == poweroff) std.process.exit(0); // system poweroff
    return;
}
