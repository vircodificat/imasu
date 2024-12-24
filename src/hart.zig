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

inline fn word(v: xlen) u32 {
    return @truncate(v);
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
        .R => |inst| {
            const x_rs1 = hart.x[inst.rs1];
            const x_rs2 = hart.x[inst.rs2];
            const shamt6: u6 = @truncate(x_rs2);
            const shamt5: u5 = @truncate(x_rs2);
            defer hart.x[0] = 0;
            hart.x[inst.rd] = switch (inst.opcode) {
                .add => x_rs1 +% x_rs2,
                .addw => sext_to_xlen(word(x_rs1) +% word(x_rs2)),
                .sub => x_rs1 -% x_rs2,
                .subw => sext_to_xlen(word(x_rs1) -% word(x_rs2)),
                .sll => x_rs1 << shamt6,
                .sllw => sext_to_xlen(word(x_rs1) << shamt5),
                .slt => if (signed(x_rs1) < signed(x_rs2)) 1 else 0,
                .sltu => if (x_rs1 < x_rs2) 1 else 0,
                .xor => x_rs1 ^ x_rs2,
                .srl => x_rs1 >> shamt6,
                .srlw => zext_to_xlen(word(x_rs1) >> shamt5),
                .sra => unsigned(signed(x_rs1) >> shamt6),
                .sraw => sext_to_xlen(signed(word(x_rs1)) >> shamt5),
                .@"or" => x_rs1 | x_rs2,
                .@"and" => x_rs1 & x_rs2,
                else => return Exception.IllegalInstruction,
            };
            hart.pc +%= 4;
            return;
        },
        .I => |inst| {
            const x_rs1 = hart.x[inst.rs1];
            const imm = sext_to_xlen(inst.imm);
            const shamt6: u6 = @truncate(imm);
            const shamt5: u5 = @truncate(imm);
            defer hart.x[0] = 0;
            hart.x[inst.rd] = switch (inst.opcode) {
                .jalr => { // TODO: executable permission check for jump target
                    const jump_target = x_rs1 +% imm & ~@as(xlen, 0b1);
                    if (inst.rd != 0) hart.x[inst.rd] = hart.pc +% 4;
                    if (jump_target % 4 != 0) return error.InstMisaligned;
                    hart.pc = jump_target;
                    return;
                },
                .lb => sext_to_xlen(try hart.mem.load_byte(x_rs1 +% imm)),
                .lh => sext_to_xlen(try hart.mem.load_half(x_rs1 +% imm)),
                .lw => sext_to_xlen(try hart.mem.load_word(x_rs1 +% imm)),
                .ld => try hart.mem.load_double(x_rs1 +% imm),
                .lbu => zext_to_xlen(try hart.mem.load_byte(x_rs1 +% imm)),
                .lhu => zext_to_xlen(try hart.mem.load_half(x_rs1 +% imm)),
                .lwu => zext_to_xlen(try hart.mem.load_word(x_rs1 +% imm)),
                .addi => x_rs1 +% imm,
                .addiw => sext_to_xlen(word(x_rs1) +% word(imm)),
                .slti => if (signed(x_rs1) < signed(imm)) 1 else 0,
                .sltiu => if (x_rs1 < imm) 1 else 0,
                .xori => x_rs1 ^ imm,
                .ori => x_rs1 | imm,
                .andi => x_rs1 & imm,
                .slli => x_rs1 << shamt6,
                .slliw => sext_to_xlen(word(x_rs1) << shamt5),
                .srli => x_rs1 >> shamt6,
                .srliw => zext_to_xlen(word(x_rs1) >> shamt5),
                .srai => unsigned(signed(x_rs1) >> shamt6),
                .sraiw => sext_to_xlen(signed(word(x_rs1)) >> shamt5),
            };
            hart.pc +%= 4;
            return;
        },
        .CSR => |inst| {
            const x_rs1 = hart.x[inst.rs1];
            switch (inst.opcode) {
                .csrrw => { // no read if rd=x0, always write
                    if (inst.rd != 0) hart.x[inst.rd] = try hart.csrs.read(inst.csrno, hart.priv);
                    try hart.csrs.write(inst.csrno, hart.priv, x_rs1);
                },
                .csrrs => { // always read, no write if rs1=x0
                    const v = try hart.csrs.read(inst.csrno, hart.priv);
                    if (inst.rd != 0) hart.x[inst.rd] = v;
                    if (inst.rs1 != 0) try hart.csrs.write(inst.csrno, hart.priv, v | x_rs1);
                },
                .csrrc => { // always read, no write if rs1=x0
                    const v = try hart.csrs.read(inst.csrno, hart.priv);
                    if (inst.rd != 0) hart.x[inst.rd] = v;
                    if (inst.rs1 != 0) try hart.csrs.write(inst.csrno, hart.priv, v & ~x_rs1);
                },
                .csrrwi => { // no read if rd=x0, always write
                    if (inst.rd != 0) hart.x[inst.rd] = try hart.csrs.read(inst.csrno, hart.priv);
                    try hart.csrs.write(inst.csrno, hart.priv, zext_to_xlen(inst.rs1));
                },
                .csrrsi => { // always read, no write if rs1=x0
                    const v = try hart.csrs.read(inst.csrno, hart.priv);
                    if (inst.rd != 0) hart.x[inst.rd] = v;
                    if (inst.rs1 != 0) try hart.csrs.write(inst.csrno, hart.priv, v | zext_to_xlen(inst.rs1));
                },
                .csrrci => { // always read, no write if rs1=x0
                    const v = try hart.csrs.read(inst.csrno, hart.priv);
                    if (inst.rd != 0) hart.x[inst.rd] = v;
                    if (inst.rs1 != 0) try hart.csrs.write(inst.csrno, hart.priv, v & ~zext_to_xlen(inst.rs1));
                },
            }
            hart.pc +%= 4;
            return;
        },
        .S => |inst| {
            const x_rs1 = hart.x[inst.rs1];
            const x_rs2 = hart.x[inst.rs2];
            const imm = sext_to_xlen(inst.imm);
            const addr = x_rs1 +% imm;
            switch (inst.opcode) {
                .sb => try hart.mem.store_byte(addr, @truncate(x_rs2)),
                .sh => try hart.mem.store_half(addr, @truncate(x_rs2)),
                .sw => try hart.mem.store_word(addr, @truncate(x_rs2)),
                .sd => try hart.mem.store_double(addr, x_rs2),
            }
            hart.pc +%= 4;
            return;
        },
        .B => |inst| { // TODO: executable permission check for branch target
            const x_rs1 = hart.x[inst.rs1];
            const x_rs2 = hart.x[inst.rs2];
            const imm = sext_to_xlen(inst.imm) << 1;
            const branch = switch (inst.opcode) {
                .beq => x_rs1 == x_rs2,
                .bne => x_rs1 != x_rs2,
                .blt => signed(x_rs1) < signed(x_rs2),
                .bge => signed(x_rs1) >= signed(x_rs2),
                .bltu => x_rs1 < x_rs2,
                .bgeu => x_rs1 >= x_rs2,
            };
            if (branch) {
                const branch_target = hart.pc +% imm;
                if (branch_target % 4 != 0) return Exception.InstMisaligned;
                hart.pc = branch_target;
                return;
            } else { // fallthrough
                hart.pc +%= 4;
                return;
            }
        },
        .U => |inst| {
            const imm = sext_to_xlen(@as(u32, inst.imm) << 12);
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
