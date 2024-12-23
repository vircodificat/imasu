// RISC-V Instruction encoder, primarily used for testing the decoder

const Instruction = @import("instruction.zig").Instruction;
const Opcode = @import("instruction.zig").Opcode;
const decode = @import("decode.zig");

const std = @import("std");
const expect = std.testing.expect;

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
