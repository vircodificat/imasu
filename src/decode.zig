// RISC-V Instruction decoder

const std = @import("std");

// Decode immediate value from I-type instruction
// 31 ... 20 | 19 ... 0
// imm[11:0] |
pub fn decode_i_type_immediate(bits: u32) i12 {
    const imm_bits: u12 = @truncate(bits >> 20);
    return @bitCast(imm_bits);
}

// Decode immediate value from S-type instruction
// 31 ... 25 | 24 ... 12 | 11 ... 7 | 6 ... 0
// imm[11:5] |           | imm[4:0] |
pub fn decode_s_type_immediate(bits: u32) i12 {
    const @"imm11:5": u32 = ((bits >> 25) & 0b111_1111) << 5;
    const @"imm4:0": u32 = (bits >> 7) & 0b1_1111;
    const imm_bits: u12 = @truncate(@"imm11:5" | @"imm4:0");
    return @bitCast(imm_bits);
}

// Decode immediate value from B-type instruction
// 31      | 30 ... 25 | 24 ... 12 | 11 ... 8 | 7       | 6 ... 0
// imm[12] | imm[10:5] |           | imm[4:1] | imm[11] |
pub fn decode_b_type_immediate(bits: u32) i13 {
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
pub fn decode_u_type_immediate(bits: u32) i32 {
    const @"imm31:12": u32 = ((bits >> 12) & 0xf_ffff) << 12;
    return @bitCast(@"imm31:12");
}

// Decode immediate value from J-type instruction
// 31      | 30 ... 21 | 20      | 19 ... 12  | 11 ... 0
// imm[20] | imm[10:1] | imm[11] | imm[19:12] |
pub fn decode_j_type_immediate(bits: u32) i21 {
    const imm20 = ((bits >> 31) & 0b1) << 20;
    const @"imm19:12" = ((bits >> 12) & 0xff) << 12;
    const imm11 = ((bits >> 20) & 0b1) << 11;
    const @"imm10:1" = ((bits >> 21) & 0x3ff) << 1;
    const imm_bits: u21 = @truncate(imm20 | @"imm19:12" | imm11 | @"imm10:1");
    return @bitCast(imm_bits);
}


test "all valid J-type immediates decode" {
    var value: i21 = std.math.minInt(i21);
    while (true) {
        try std.testing.expect(decode_j_type_immediate(try encode_j_type_immediate(value)) == value);
        if (value == std.math.maxInt(i21) & 0b0) break;
        value += 2;
    }
}
