// RISC-V Instruction decoder

const std = @import("std");

// Decode immediate value from I-type instruction
// 31 ... 20 | 19 ... 0
// imm[11:0] |
fn decode_i_type_immediate(bits: u32) i12 {
    const imm_bits: u12 = @truncate(bits >> 20);
    return @bitCast(imm_bits);
}

// Decode immediate value from S-type instruction
// 31 ... 25 | 24 ... 12 | 11 ... 7 | 6 ... 0
// imm[11:5] |           | imm[4:0] |
fn decode_s_type_immediate(bits: u32) i12 {
    const @"imm11:5": u32 = ((bits >> 25) & 0b111_1111) << 5;
    const @"imm4:0": u32 = (bits >> 7) & 0b1_1111;
    const imm_bits: u12 = @truncate(@"imm11:5" | @"imm4:0");
    return @bitCast(imm_bits);
}

// Decode immediate value from B-type instruction
// 31      | 30 ... 25 | 24 ... 12 | 11 ... 8 | 7       | 6 ... 0
// imm[12] | imm[10:5] |           | imm[4:1] | imm[11] |
fn decode_b_type_immediate(bits: u32) i13 {
    const imm12 = ((bits >> 31) & 0b1) << 12;
    const imm11 = ((bits >> 7) & 0b1) << 11;
    const @"imm10:5" = ((bits >> 25) & 0b11_1111) << 5;
    const @"imm4:1" = ((bits >> 8) & 0b1111) << 1;
    const imm_bits: u13 = @truncate(imm12 | imm11 | @"imm10:5" | @"imm4:1");
    return @bitCast(imm_bits);
}

// Decode immediate value from U-type instruction
// 31 ... 12  | 11 ... 0
// imm[31:12] |
fn decode_u_type_immediate(bits: u32) i32 {
    const @"imm31:12": u32 = ((bits >> 12) & 0xf_ffff) << 12;
    return @bitCast(@"imm31:12");
}

// Decode immediate value from J-type instruction
// 31      | 30 ... 21 | 20      | 19 ... 12  | 11 ... 0
// imm[20] | imm[10:1] | imm[11] | imm[19:12] |
fn decode_j_type_immediate(bits: u32) i21 {
    const imm20 = ((bits >> 31) & 0b1) << 20;
    const @"imm19:12" = ((bits >> 12) & 0xff) << 12;
    const imm11 = ((bits >> 20) & 0b1) << 11;
    const @"imm10:1" = ((bits >> 21) & 0x3ff) << 1;
    const imm_bits: u21 = @truncate(imm20 | @"imm19:12" | imm11 | @"imm10:1");
    return @bitCast(imm_bits);
}

// Encode immediate value in instruction encoding types, for the purposes of writing tests

// Encode immediate value for I-type instruction
fn encode_i_type_immediate(value: i12) u32 {
    const imm: u32 = @bitCast(@as(i32, value));
    const inst_bits: u32 = imm << 20;
    return inst_bits;
}

// Encode immediate value for S-type instruction
fn encode_s_type_immediate(value: i12) u32 {
    const imm: u32 = @bitCast(@as(i32, value));
    const @"inst31:25" = ((imm >> 5) & 0b111_1111) << 25;
    const @"inst11:7" = ((imm) & 0b1_1111) << 7;
    const inst_bits = @"inst31:25" | @"inst11:7";
    return inst_bits;
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

// Encode immediate value for U-type instruction
fn encode_u_type_immediate(value: i32) !u32 {
    if (value & 0xfff != 0) return error.InvalidValue;
    const imm: u32 = @bitCast(@as(i32, value));
    return imm;
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

test "all valid I-type immediates decode" {
    var value: i12 = std.math.minInt(i12);
    while (true) {
        try std.testing.expect(decode_i_type_immediate(encode_i_type_immediate(value)) == value);
        if (value == std.math.maxInt(i12)) break;
        value += 1;
    }
}

test "all valid S-type immediates decode" {
    var value: i12 = std.math.minInt(i12);
    while (true) {
        try std.testing.expect(decode_s_type_immediate(encode_s_type_immediate(value)) == value);
        if (value == std.math.maxInt(i12)) break;
        value += 1;
    }
}

test "all valid B-type immediates decode" {
    var value: i13 = std.math.minInt(i13);
    while (true) {
        try std.testing.expect(decode_b_type_immediate(try encode_b_type_immediate(value)) == value);
        if (value == std.math.maxInt(i13) & 0b0) break;
        value += 2;
    }
}

test "all valid U-type immediates decode" {
    var value: i32 = std.math.minInt(i32);
    while (true) {
        try std.testing.expect(decode_u_type_immediate(try encode_u_type_immediate(value)) == value);
        if (value == std.math.maxInt(i32) & 0x0_0000) break;
        value += 0x10_0000;
    }
}

test "all valid J-type immediates decode" {
    var value: i21 = std.math.minInt(i21);
    while (true) {
        try std.testing.expect(decode_j_type_immediate(try encode_j_type_immediate(value)) == value);
        if (value == std.math.maxInt(i21) & 0b0) break;
        value += 2;
    }
}
