// Debugging functionality

const Exception = @import("exception.zig").Exception;
const Hart = @import("hart.zig");
const std = @import("std");

const reg_name: [32][]const u8 = [32][]const u8{
    // zig fmt: off
    "zero", "ra", "sp", "gp",
    "tp", "t0", "t1", "t2",
    "s0", "s1", "a0", "a1",
    "a2", "a3", "a4", "a5",
    "a6", "a7", "s2", "s3",
    "s4", "s5", "s6", "s7",
    "s8", "s9", "s10", "s11",
    "t3", "t4", "t5", "t6",
    // zig fmt: on
};

inline fn exception_to_string(err: Exception) []const u8 {
    return switch (err) {
        Exception.InstMisaligned => "Instruction Address Misaligned",
        Exception.InstPageFault => "Instruction Fetch Page Fault",
        Exception.InstAccessFault => "Instruction Access Fault",
        Exception.IllegalInstruction => "Illegal Instruction",
        Exception.LoadMisaligned => "Load Address Misaligned",
        Exception.LoadPageFault => "Load Page Fault",
        Exception.LoadAccessFault => "Load Access Fault",
        Exception.StoreMisaligned => "Store Address Misaligned",
        Exception.StorePageFault => "Store Page Fault",
        Exception.StoreAccessFault => "Store Access Fault",
        Exception.Breakpoint => "Breakpoint",
        Exception.ECallUser => "Environment Call from U-mode",
        Exception.ECallSupervisor => "Environment Call from S-mode",
        Exception.ECallMachine => "Environment Call from M-mode",
    };
}

pub fn dump_exception(err: Exception, tval: Hart.xlen, buf: []u8) ![]u8 {
    var stream = std.io.fixedBufferStream(buf);
    const writer = stream.writer().any();
    _ = try std.fmt.format(writer, "exception occured: {s}\ntval [{x:0>16}]\n",
        .{exception_to_string(err), tval});
    return stream.getWritten();
}

pub fn dump_registers(hart:  *const Hart, buf: []u8) ![]u8 {
    var stream = std.io.fixedBufferStream(buf);
    const writer = stream.writer().any();
    _ = try std.fmt.format(writer, "  pc [{x:0>16}]\n", .{hart.pc});
    var reg: usize = 0;
    while (reg < 32) : (reg += 1) {
        if (reg % 4 != 0) _ = try writer.write(" ");
        _ = try std.fmt.format(writer, "{s: >4} [{x:0>16}]", .{reg_name[reg], hart.x[reg]});
        if (reg % 4 == 3) _ = try writer.write("\n");
    }
    return stream.getWritten();
}
