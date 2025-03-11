// System controller (Syscon) device
// https://www.kernel.org/doc/Documentation/devicetree/bindings/mfd/syscon.yaml

// this device only implements powering off the system, see the devicetree source
// https://www.kernel.org/doc/Documentation/devicetree/bindings/power/reset/syscon-poweroff.txt

const Exception = @import("../exception.zig").Exception;
const std = @import("std");

const Syscon = @This();

pub const mmio_len = 0x4;

pub const poweroff: u32 = 0x0000DEAD;

pub fn mmio_reg_read(_: *Syscon, comptime T: type, reg_addr: u64) !T {
    if (T != u32 or reg_addr != 0) return Exception.LoadAccessFault;
    return 0;
}

pub fn mmio_reg_write(_: *Syscon, comptime T: type, reg_addr: u64, v: T) !void {
    if (T != u32 or reg_addr != 0) return Exception.StoreAccessFault;
    if (v == poweroff) std.process.exit(0); // system poweroff
    return;
}
