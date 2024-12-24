// RISC-V Hart

const Instruction = @import("instruction.zig").Instruction;
const Exception = @import("exception.zig").Exception;
const Privilege = @import("priv.zig").Privilege;
const Memory = @import("memory.zig");
const CSRs = @import("csr.zig");
const decode = @import("decode.zig");
const debug = @import("debug.zig");
const std = @import("std");

const Hart = @This();

pub const xlen = u64; // integer register width
// hart state:
x: [32]xlen, // general purpose registers
pc: xlen, // program counter
csrs: CSRs, // control and status registers
priv: Privilege, // privilege level

mem: *Memory, // handle to main memory

pub fn init() Hart {
    return Hart{
        .x = .{0} ** 32,
        .pc = Memory.mem_base,
        .csrs = CSRs.init(),
        .priv = .M,
        .mem = undefined,
    };
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

inline fn u_type_imm_bits_to_value(u: u20) u32 {
    return @as(u32, u) << 12;
}

fn dump_exception_to_stderr(hart: *const Hart, err: Exception, tval: xlen) void {
    const stderr = std.io.getStdErr().writer();
    var buffer: [4096]u8 = undefined;
    var buf = debug.dump_exception(err, tval, &buffer) catch unreachable;
    _ = stderr.write(buf) catch {};
    buf = debug.dump_registers(hart, &buffer) catch unreachable;
    _ = stderr.write(buf) catch {};
}

// perform a fetch-decode-execute cycle of the hart
pub fn step(hart: *Hart) void {
    // fetch instruction
    const ints_bits = hart.mem.fetch_instruction(hart.pc) catch |err| {
        hart.trap_on_exception(err, hart.pc);
        return;
    };
    // decode instruction
    const instruction = decode.instruction(ints_bits) catch |err| {
        hart.trap_on_exception(err, ints_bits);
        return;
    };
    // execute instruction
    hart.execute(instruction) catch |err| {
        hart.trap_on_exception(err, ints_bits);
        return;
    };
}

fn trap_on_exception(hart: *Hart, err: Exception, tval: xlen) void {
    hart.dump_exception_to_stderr(err, tval);
    // TODO: S-mode delegation when S-mode is implemented

    // push mie to mpie, mie becomes false
    hart.csrs.mstatus.mpie = hart.csrs.mstatus.mie;
    hart.csrs.mstatus.mie = false;
    // push current privilege to mpp, privilege becomes M-mode
    hart.csrs.mstatus.mpp = hart.priv;
    hart.priv = .M;
    // store pc into mepc
    hart.csrs.mepc = hart.pc;
    // store exception cause and value
    hart.csrs.mtval = tval;
    hart.csrs.mcause = CSRs.exception_to_xcause_csr_value(err);
    // set program counter to trap vector base
    // as this is the trap procedure for exceptions not interrupts,
    // we always go to the base address
    hart.pc = hart.csrs.mtvec.base;
}

fn execute(hart: *Hart, instruction: Instruction) Exception!void { // TODO
    switch (instruction) {
        .U => |inst| {
            const imm = sext_to_xlen(u_type_imm_bits_to_value(inst.imm));
            if (inst.rd != 0) hart.x[inst.rd] = switch (inst.opcode) {
                .lui => imm,
                .auipc => hart.pc +% imm,
            };
            hart.pc +%= 4;
            return;
        },
        .J => |inst| { // TODO: executable permission check for jump target
            const imm = sext_to_xlen(inst.imm) << 1;
            const jump_target = hart.pc +% imm;
            if (inst.rd != 0) hart.x[inst.rd] = hart.pc +% 4;
            if (jump_target % 4 != 0) return Exception.InstMisaligned;
            hart.pc = jump_target;
            return;
        },
        else => return Exception.IllegalInstruction,
    }
}
