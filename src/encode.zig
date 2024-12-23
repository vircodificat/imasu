// RISC-V Instruction encoder, primarily used for testing the decoder

const Opcode = @import("instruction.zig").Opcode;
const Operands = @import("instruction.zig").Operands;
const decode = @import("decode.zig");

const std = @import("std");
const assert = std.debug.assert;
const expect = std.testing.expect;

const reg_bound = std.math.maxInt(u5) + 1;

// Count number of variants of enum
fn num_variants(T: anytype) usize {
    return @typeInfo(T).@"enum".fields.len;
}

// Encode immediate value in instruction encoding types

// Encode immediate bits for I-type instruction
fn i_type_immediate(bits: u12) u32 {
    const inst_bits: u32 = @as(u32, bits) << 20;
    return inst_bits;
}

test "I-type immediate decode" {
    var imm: u12 = std.math.minInt(u12);
    while (true) : (imm += 1) {
        const encoded = i_type_immediate(imm);
        const decoded = decode.i_type_immediate(encoded);
        try expect(decoded == imm);
        if (imm == std.math.maxInt(u12)) break;
    }
}

// Encode immediate bits for S-type instruction
fn s_type_immediate(bits: u12) u32 {
    const imm: u32 = @as(u32, bits);
    const @"inst31:25" = ((imm >> 5) & 0b111_1111) << 25;
    const @"inst11:7" = ((imm) & 0b1_1111) << 7;
    const inst_bits = @"inst31:25" | @"inst11:7";
    return inst_bits;
}

test "S-type immediate decode" {
    var imm: u12 = std.math.minInt(u12);
    while (true) : (imm += 1) {
        const encoded = s_type_immediate(imm);
        const decoded = decode.s_type_immediate(encoded);
        try expect(decoded == imm);
        if (imm == std.math.maxInt(u12)) break;
    }
}

// Encode immediate bits for B-type instruction
fn b_type_immediate(bits: u12) u32 {
    const imm: u32 = @as(u32, bits) << 1;
    const inst31 = ((imm >> 12) & 0b1) << 31;
    const @"inst30:25" = ((imm >> 5) & 0b11_1111) << 25;
    const @"inst11:8" = ((imm >> 1) & 0b1111) << 8;
    const inst7 = ((imm >> 11) & 0b1) << 7;
    const inst_bits = inst31 | @"inst30:25" | @"inst11:8" | inst7;
    return inst_bits;
}

test "B-type immediate decode" {
    var imm: u12 = std.math.minInt(u12);
    while (true) : (imm += 1) {
        const encoded = b_type_immediate(imm);
        const decoded = decode.b_type_immediate(encoded);
        try expect(decoded == imm);
        if (imm == std.math.maxInt(u12)) break;
    }
}

// Encode immediate bits for U-type instruction
fn u_type_immediate(bits: u20) u32 {
    return @as(u32, bits) << 12;
}

test "U-type immediate decode" {
    var imm: u20 = std.math.minInt(u20);
    while (true) : (imm += 1) {
        const encoded = u_type_immediate(imm);
        const decoded = decode.u_type_immediate(encoded);
        try expect(decoded == imm);
        if (imm == std.math.maxInt(u20)) break;
    }
}

// Encode immediate bits for J-type instruction
fn j_type_immediate(bits: u20) u32 {
    const imm: u32 = @as(u32, bits) << 1;
    const inst31 = ((imm >> 20) & 0b1) << 31;
    const @"inst31:21" = ((imm >> 1) & 0x3ff) << 21;
    const inst20 = ((imm >> 11) & 0b1) << 20;
    const @"inst19:12" = ((imm >> 12) & 0xff) << 12;
    const inst_bits = inst31 | @"inst31:21" | inst20 | @"inst19:12";
    return inst_bits;
}

test "J-type immediate decode" {
    var imm: u20 = std.math.minInt(u20);
    while (true) : (imm += 1) {
        const encoded = j_type_immediate(imm);
        const decoded = decode.j_type_immediate(encoded);
        try expect(decoded == imm);
        if (imm == std.math.maxInt(u20)) break;
    }
}

// Encode funct3 in instruction
inline fn funct3_field(f: u3) u32 {
    return @as(u32, f) << 12;
}

// Encode funct7 in instruction
inline fn funct7_field(f: u7) u32 {
    return @as(u32, f) << 25;
}

// Encode rs1 in instruction
inline fn rs1_field(reg: u5) u32 {
    return @as(u32, reg) << 15;
}

// Encode rs2 in instruction
inline fn rs2_field(reg: u5) u32 {
    return @as(u32, reg) << 20;
}

// Encode rd in instruction
inline fn rd_field(reg: u5) u32 {
    return @as(u32, reg) << 7;
}

// R-type instruction opcode to instruction funct3 field
fn r_type_funct3(opcode: Opcode.R) u3 {
    return switch (opcode) {
        .add, .addw, .sub, .subw, .mul, .mulw => 0b000,
        .sll, .sllw, .mulh => 0b001,
        .slt, .mulhsu => 0b010,
        .sltu, .mulhu => 0b011,
        .xor, .div, .divw => 0b100,
        .srl, .sra, .srlw, .sraw, .divu, .divuw => 0b101,
        .@"or", .rem, .remw => 0b110,
        .@"and", .remu, .remuw => 0b111,
    };
}

// R-type instruction opcode to instruction funct7 field
fn r_type_funct7(opcode: Opcode.R) u7 {
    return switch (opcode) {
        .add, .sll, .slt, .sltu, .xor, .srl, .@"or", .@"and", .addw, .sllw, .srlw => 0b0,
        .mul, .mulh, .mulhsu, .mulhu, .div, .divu, .rem, .remu, .mulw, .divw, .divuw, .remw, .remuw => 0b1,
        .sub, .sra, .subw, .sraw => 0b010_0000,
    };
}

// R-type instruction opcode to instruction opcode field
fn r_type_opcode(opcode: Opcode.R) u7 {
    return switch (opcode) {
        .add, .sub, .sll, .slt, .sltu, .xor, .srl, .sra, .@"or", .@"and", .mul, .mulh, .mulhsu, .mulhu, .div, .divu, .rem, .remu => 0b0110011,
        .addw, .subw, .sllw, .srlw, .sraw, .mulw, .divw, .divuw, .remw, .remuw => 0b0111011,
    };
}

fn r_type_instruction(inst: Operands.R) u32 {
    // zig fmt: off
    return r_type_opcode(inst.opcode)
        | rd_field(inst.rd)
        | funct3_field(r_type_funct3(inst.opcode))
        | rs1_field(inst.rs1)
        | rs2_field(inst.rs2)
        | funct7_field(r_type_funct7(inst.opcode));
    // zig fmt: on
}

test "all R-type instruction decode" {
    const num_opcodes = num_variants(Opcode.R);
    for (0..num_opcodes) |n| {
        const opcode: Opcode.R = @enumFromInt(n);
        for (0..reg_bound) |i| {
            const rs1: u5 = @intCast(i);
            for (0..reg_bound) |j| {
                const rs2: u5 = @intCast(j);
                for (0..reg_bound) |k| {
                    const rd: u5 = @intCast(k);

                    const instruction: Operands.R = .{ .opcode = opcode, .rs1 = rs1, .rs2 = rs2, .rd = rd };
                    const inst_bits = r_type_instruction(instruction);
                    const decoded_instruction = try decode.instruction(inst_bits);
                    // std.debug.print("{x:0>8} |  {s} rd:{d} rs2:{d} rs1:{d}\n", .{ inst_bits, @tagName(opcode), rd, rs2, rs1 });

                    try expect(std.meta.eql(instruction, decoded_instruction.R));
                }
            }
        }
    }
}

fn s_type_instruction(inst: Operands.S) u32 {
    const funct3: u3 = switch (inst.opcode) {
        .sb => 0b000,
        .sh => 0b001,
        .sw => 0b010,
        .sd => 0b011,
    };
    // zig fmt: off
    return 0b0100011
        | funct3_field(funct3)
        | rs1_field(inst.rs1)
        | rs2_field(inst.rs2)
        | s_type_immediate(inst.imm);
    // zig fmt: on
}

test "all S-type instruction decode" {
    const num_opcodes = num_variants(Opcode.S);
    for (0..num_opcodes) |n| {
        const opcode: Opcode.S = @enumFromInt(n);
        for (0..reg_bound) |i| {
            const rs1: u5 = @intCast(i);
            for (0..reg_bound) |j| {
                const rs2: u5 = @intCast(j);
                for (0..std.math.maxInt(u12) + 1) |k| {
                    const imm_bits: u12 = @intCast(k);

                    const instruction: Operands.S = .{ .opcode = opcode, .rs1 = rs1, .rs2 = rs2, .imm = imm_bits };
                    const inst_bits = s_type_instruction(instruction);
                    const decoded_instruction = try decode.instruction(inst_bits);

                    try expect(std.meta.eql(instruction, decoded_instruction.S));
                }
            }
        }
    }
}

fn b_type_instruction(inst: Operands.B) u32 {
    const funct3: u3 = switch (inst.opcode) {
        .beq => 0b000,
        .bne => 0b001,
        .blt => 0b100,
        .bge => 0b101,
        .bltu => 0b110,
        .bgeu => 0b111,
    };
    // zig fmt: off
    return 0b1100011
        | funct3_field(funct3)
        | rs1_field(inst.rs1)
        | rs2_field(inst.rs2)
        | b_type_immediate(inst.imm);
    // zig fmt: on
}

test "all B-type instruction decode" {
    const num_opcodes = num_variants(Opcode.B);
    for (0..num_opcodes) |n| {
        const opcode: Opcode.B = @enumFromInt(n);
        for (0..reg_bound) |i| {
            const rs1: u5 = @intCast(i);
            for (0..reg_bound) |j| {
                const rs2: u5 = @intCast(j);
                for (0..std.math.maxInt(u12) + 1) |k| {
                    const imm_bits: u12 = @intCast(k);

                    const instruction: Operands.B = .{ .opcode = opcode, .rs1 = rs1, .rs2 = rs2, .imm = imm_bits };
                    const inst_bits = b_type_instruction(instruction);
                    const decoded_instruction = try decode.instruction(inst_bits);

                    try expect(std.meta.eql(instruction, decoded_instruction.B));
                }
            }
        }
    }
}

fn u_type_instruction(inst: Operands.U) u32 {
    const opcode_field: u7 = switch (inst.opcode) {
        .lui => 0b0110111,
        .auipc => 0b0010111,
    };
    return opcode_field | rd_field(inst.rd) | u_type_immediate(inst.imm);
}

test "all U-type instruction decode" {
    const num_opcodes = num_variants(Opcode.U);
    for (0..num_opcodes) |n| {
        const opcode: Opcode.U = @enumFromInt(n);
        for (0..reg_bound) |i| {
            const rd: u5 = @intCast(i);
            for (0..std.math.maxInt(u20) + 1) |j| {
                const imm_bits: u20 = @intCast(j);

                const instruction: Operands.U = .{ .opcode = opcode, .rd = rd, .imm = imm_bits };
                const inst_bits = u_type_instruction(instruction);
                const decoded_instruction = try decode.instruction(inst_bits);

                try expect(std.meta.eql(instruction, decoded_instruction.U));
            }
        }
    }
}

fn jal_instruction(inst: Operands.J) u32 {
    assert(inst.opcode == .jal);
    return 0b1101111 | rd_field(inst.rd) | j_type_immediate(inst.imm);
}

test "all J-type instruction decode" {
    for (0..reg_bound) |i| {
        const rd: u5 = @intCast(i);
        for (0..std.math.maxInt(u20) + 1) |j| {
            const imm_bits: u20 = @intCast(j);

            const instruction: Operands.J = .{ .opcode = .jal, .rd = rd, .imm = imm_bits };
            const inst_bits = jal_instruction(instruction);
            const decoded_instruction = try decode.instruction(inst_bits);

            try expect(std.meta.eql(instruction, decoded_instruction.J));
        }
    }
}
