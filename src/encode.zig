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

// Encode immediate value for I-type instruction
fn encode_i_type_immediate(value: i12) u32 {
    const imm: u32 = @bitCast(@as(i32, value));
    const inst_bits: u32 = imm << 20;
    return inst_bits;
}

test "I-type immediate decode" {
    // I-type immediates are integers -2048 to 2047
    const decode_i_type_immediate = decode.decode_i_type_immediate;
    var imm: i12 = std.math.minInt(i12);
    while (true) : (imm += 1) {
        const encoded = encode_i_type_immediate(imm);
        const decoded = decode_i_type_immediate(encoded);
        try expect(decoded == imm);
        if (imm == std.math.maxInt(i12)) break;
    }
}

// Encode immediate value for S-type instruction
fn encode_s_type_immediate(value: i12) u32 {
    const imm: u32 = @bitCast(@as(i32, value));
    const @"inst31:25" = ((imm >> 5) & 0b111_1111) << 25;
    const @"inst11:7" = ((imm) & 0b1_1111) << 7;
    const inst_bits = @"inst31:25" | @"inst11:7";
    return inst_bits;
}

test "S-type immediate decode" {
    // S-type immediates are integers -2048 to 2047
    const decode_s_type_immediate = decode.decode_s_type_immediate;
    var imm: i12 = std.math.minInt(i12);
    const imm_max = std.math.maxInt(i12);
    while (true) : (imm += 1) {
        const encoded = encode_s_type_immediate(imm);
        const decoded = decode_s_type_immediate(encoded);
        try expect(decoded == imm);
        if (imm == imm_max) break;
    }
}

// Encode immediate value for B-type instruction
fn encode_b_type_immediate(value: i13) !u32 {
    if (value & 0b1 != 0) return error.InvalidValue;
    const imm: u32 = @bitCast(@as(i32, value));
    const inst31 = ((imm >> 12) & 0b1) << 31;
    const @"inst30:25" = ((imm >> 5) & 0b11_1111) << 25;
    const @"inst11:8" = ((imm >> 1) & 0b1111) << 8;
    const inst7 = ((imm >> 11) & 0b1) << 7;
    const inst_bits = inst31 | @"inst30:25" | @"inst11:8" | inst7;
    return inst_bits;
}

test "B-type immediate decode" {
    // B-type immediates are even integers -4096 to 4094
    const decode_b_type_immediate = decode.decode_b_type_immediate;
    var imm: i13 = std.math.minInt(i13);
    const imm_max = std.math.maxInt(i13) & ~@as(u13, 0b1);
    while (true) : (imm += 2) {
        const encoded = try encode_b_type_immediate(imm);
        const decoded = decode_b_type_immediate(encoded);
        try expect(decoded == imm);
        if (imm == imm_max) break;
    }
}

// Encode immediate value for U-type instruction
fn encode_u_type_immediate(value: i32) !u32 {
    if (value & 0xfff != 0) return error.InvalidValue;
    const imm: u32 = @bitCast(@as(i32, value));
    return imm;
}

test "U-type immediate decode" {
    // U-type immediates are 32-bit integers with the last 12 bits 0s
    const decode_u_type_immediate = decode.decode_u_type_immediate;
    var imm: i32 = std.math.minInt(i32);
    const imm_max = std.math.maxInt(i32) & ~@as(u32, 0xfff);
    while (true) : (imm += 0x1000) {
        const encoded = try encode_u_type_immediate(imm);
        const decoded = decode_u_type_immediate(encoded);
        try expect(decoded == imm);
        if (imm == imm_max) break;
    }
}

// Encode immediate value for J-type instruction
fn encode_j_type_immediate(value: i21) !u32 {
    if (value & 0b1 != 0) return error.InvalidValue;
    const imm: u32 = @bitCast(@as(i32, value));
    const inst31 = ((imm >> 20) & 0b1) << 31;
    const @"inst31:21" = ((imm >> 1) & 0x3ff) << 21;
    const inst20 = ((imm >> 11) & 0b1) << 20;
    const @"inst19:12" = ((imm >> 12) & 0xff) << 12;
    const inst_bits = inst31 | @"inst31:21" | inst20 | @"inst19:12";
    return inst_bits;
}

test "J-type immediate decode" {
    // J-type immediates are even integers 21-bit integers
    const decode_j_type_immediate = decode.decode_j_type_immediate;
    var imm: i21 = std.math.minInt(i21);
    const imm_max = std.math.maxInt(i21) & ~@as(u21, 0b1);
    while (true) : (imm += 2) {
        const encoded = try encode_j_type_immediate(imm);
        const decoded = decode_j_type_immediate(encoded);
        try expect(decoded == imm);
        if (imm == imm_max) break;
    }
}
