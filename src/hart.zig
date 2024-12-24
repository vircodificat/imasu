// RISC-V Hart

const Instruction = @import("instruction.zig").Instruction;
const Exception = @import("exception.zig").Exception;
const Privilege = @import("priv.zig").Privilege;
const Memory = @import("memory.zig").Memory;
const decode = @import("decode.zig");
const std = @import("std");

const Hart = @This();

const xlen = u64; // integer register width
// hart state:
x: [32]xlen, // general purpose registerss
pc: xlen, // program counter
priv: Privilege, // privilege level

mem: *Memory, // handle to main memory

pub fn init() Hart {
    return Hart{
        .x = .{0} ** 32,
        .pc = Memory.mem_base,
        .priv = .M,
        .mem = undefined,
    };
}

// perform a fetch-decode-execute cycle of the hart
pub fn step(hart: Hart) void {
    // fetch instruction
    const ints_bits = hart.mem.fetch_instruction(hart.pc) catch |err| hart.trap_on_exception(err);
    // decode instruction
    const instruction = decode.instruction(ints_bits) catch |err| hart.trap_on_exception(err);
    // execute instruction
    hart.execute(instruction) catch |err| hart.trap_on_exception(err);
}

fn trap_on_exception(hart: Hart, err: Exception) void { // TODO
    _ = hart;
    _ = err;
}

fn execute(hart: Hart, instruction: Instruction) Exception!void { // TODO
    _ = hart;
    switch (instruction) {
        else => return Exception.IllegalInstruction,
    }
}

// cast to unsigned
inline fn unsigned(value: anytype) std.meta.Int(.unsigned, @typeInfo(@TypeOf(value)).int.bits) {
    return @bitCast(value);
}
// cast to signed
inline fn signed(value: anytype) std.meta.Int(.signed, @typeInfo(@TypeOf(value)).int.bits) {
    return @bitCast(value);
}
// zero-extend to xlen
inline fn zext_to_xlen(value: anytype) xlen {
    const v = unsigned(value);
    return @as(xlen, v);
}
// sign-extend to xlen
inline fn sext_to_xlen(value: anytype) xlen {
    const signed_xlen = std.meta.Int(.signed, @typeInfo(xlen).int.bits);
    return @bitCast(@as(signed_xlen, signed(value)));
}
