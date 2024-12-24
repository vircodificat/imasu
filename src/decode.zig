// RISC-V Instruction decoder

const Instruction = @import("instruction.zig").Instruction;
const Opcode = @import("instruction.zig").Opcode;

const std = @import("std");

// Decode immediate value from I-type instruction
// 31 ... 20 | 19 ... 0
// imm[11:0] |
pub fn i_type_immediate(bits: u32) u12 {
    return @truncate(bits >> 20);
}

// Decode immediate value from S-type instruction
// 31 ... 25 | 24 ... 12 | 11 ... 7 | 6 ... 0
// imm[11:5] |           | imm[4:0] |
pub fn s_type_immediate(bits: u32) u12 {
    const @"imm11:5": u32 = ((bits >> 25) & 0b111_1111) << 5;
    const @"imm4:0": u32 = (bits >> 7) & 0b1_1111;
    return @truncate(@"imm11:5" | @"imm4:0");
}

// Decode immediate value from B-type instruction
// 31      | 30 ... 25 | 24 ... 12 | 11 ... 8 | 7       | 6 ... 0
// imm[12] | imm[10:5] |           | imm[4:1] | imm[11] |
pub fn b_type_immediate(bits: u32) u12 {
    const imm12 = ((bits >> 31) & 0b1) << 11;
    const imm11 = ((bits >> 7) & 0b1) << 10;
    const @"imm10:5" = ((bits >> 25) & 0b11_1111) << 4;
    const @"imm4:1" = ((bits >> 8) & 0b1111);
    return @truncate(imm12 | imm11 | @"imm10:5" | @"imm4:1");
}

// Decode immediate value from U-type instruction
// 31 ... 12  | 11 ... 0
// imm[31:12] |
pub fn u_type_immediate(bits: u32) u20 {
    return @truncate(bits >> 12);
}

// Decode immediate value from J-type instruction
// 31      | 30 ... 21 | 20      | 19 ... 12  | 11 ... 0
// imm[20] | imm[10:1] | imm[11] | imm[19:12] |
pub fn j_type_immediate(bits: u32) u20 {
    const imm20 = ((bits >> 31) & 0b1) << 19;
    const @"imm19:12" = ((bits >> 12) & 0xff) << 11;
    const imm11 = ((bits >> 20) & 0b1) << 10;
    const @"imm10:1" = ((bits >> 21) & 0x3ff);
    return @truncate(imm20 | @"imm19:12" | imm11 | @"imm10:1");
}

// Decode a 32-bit instruction
pub fn instruction(bits: u32) !Instruction {
    if (bits & 0b11 != 0b11) return error.IllegalInstruction;
    // instruction bitfields
    const opcode: u5 = @truncate(bits >> 2);
    const funct3: u3 = @truncate(bits >> 12);
    const funct7: u7 = @truncate(bits >> 25);
    const rd: u5 = @truncate(bits >> 7);
    const rs1: u5 = @truncate(bits >> 15);
    const rs2: u5 = @truncate(bits >> 20);

    switch (opcode) {
        0b00000 => { // lb, lh, lw, ld, lbu, lhu, lwu
            const imm = i_type_immediate(bits);
            const op: Opcode.I = switch (funct3) {
                0b000 => .lb,
                0b001 => .lh,
                0b010 => .lw,
                0b011 => .ld,
                0b100 => .lbu,
                0b101 => .lhu,
                0b110 => .lwu,
                else => return error.IllegalInstruction,
            };
            return Instruction{ .I = .{ .opcode = op, .rs1 = rs1, .rd = rd, .imm = imm } };
        },
        0b00011 => { // fence, fence.i
            // TODO: for fence, save rs1, rd, fm, pred, succ
            // TODO: for fence.i, save rs1, rd, imm (I-type)
            const op: Opcode.Special = switch (funct3) {
                0b000 => .fence,
                0b001 => .@"fence.i",
                else => return error.IllegalInstruction,
            };
            return Instruction{ .Special = op };
        },
        0b00100 => { // addi, slli, slti, sltiu, xori, srli, srai, ori, andi
            const imm = i_type_immediate(bits);
            const funct7_bit6: u1 = @truncate(funct7 >> 5);
            const op: Opcode.I = switch (funct3) {
                0b000 => .addi,
                0b001 => .slli,
                0b010 => .slti,
                0b011 => .sltiu,
                0b100 => .xori,
                0b101 => if (funct7_bit6 != 0b0) .srai else .srli,
                0b110 => .ori,
                0b111 => .andi,
            };
            switch (funct3) {
                // slli must have upper 6 bits zeroed out
                0b001 => if (funct7 & 0b111_1110 != 0) return error.IllegalInstruction,
                // srai, srli must have no other bits set in upper 6 bits of immediate,
                // besides their distinguishing bit
                0b101 => if (funct7 & 0b101_1110 != 0) return error.IllegalInstruction,
                else => {},
            }
            if (op == .srai) { // srai must mask out bit 6 of funct7 out of the immediate
                return Instruction{ .I = .{ .opcode = op, .rs1 = rs1, .rd = rd, .imm = imm & 0b1011_1111_1111 } };
            }
            return Instruction{ .I = .{ .opcode = op, .rs1 = rs1, .rd = rd, .imm = imm } };
        },
        0b00101 => { // auipc
            const imm = u_type_immediate(bits);
            return Instruction{ .U = .{ .opcode = .auipc, .rd = rd, .imm = imm } };
        },
        0b00110 => { // addiw, slliw, srliw, sraiw
            const imm = i_type_immediate(bits);
            const funct7_bit6: u1 = @truncate(funct7 >> 5);
            const op: Opcode.I = switch (funct3) {
                0b000 => .addiw,
                0b001 => .slliw,
                0b101 => if (funct7_bit6 != 0b0) .sraiw else .srliw,
                else => return error.IllegalInstruction,
            };
            switch (funct3) {
                // slliw must have upper 7 bits zeroed out
                0b001 => if (funct7 != 0) return error.IllegalInstruction,
                // sraiw, srliw must have no other bits set in the upper 7 bits of immediate,
                // besides their distinguishing bit
                0b101 => if (funct7 & 0b101_1111 != 0) return error.IllegalInstruction,
                else => {},
            }
            if (op == .sraiw) { // sraiw must mask out bit 6 of funct7 out of the immediate
                return Instruction{ .I = .{ .opcode = op, .rs1 = rs1, .rd = rd, .imm = imm & 0b1011_1111_1111 } };
            }
            return Instruction{ .I = .{ .opcode = op, .rs1 = rs1, .rd = rd, .imm = imm } };
        },
        0b01000 => { // sb, sh, sw, sd
            const imm = s_type_immediate(bits);
            const op: Opcode.S = switch (funct3) {
                0b000 => .sb,
                0b001 => .sh,
                0b010 => .sw,
                0b011 => .sd,
                else => return error.IllegalInstruction,
            };
            return Instruction{ .S = .{ .opcode = op, .rs1 = rs1, .rs2 = rs2, .imm = imm } };
        },
        0b01011 => { // AMO instructions
            if (funct3 != 0b010 or funct3 != 0b011) return error.IllegalInstruction;
            const funct7_top5: u5 = @truncate(funct7 >> 2);
            const funct3_bit1: u1 = @truncate(funct3);
            const op: Opcode.AMO = switch (funct3_bit1) {
                0b0 => switch (funct7_top5) { // word-size operations
                    0b00000 => .@"amoadd.w",
                    0b00001 => .@"amoswap.w",
                    0b00010 => .@"lr.w",
                    0b00011 => .@"sc.w",
                    0b00100 => .@"amoxor.w",
                    0b01000 => .@"amoor.w",
                    0b01100 => .@"amoand.w",
                    0b10000 => .@"amomin.w",
                    0b10100 => .@"amomax.w",
                    0b11000 => .@"amominu.w",
                    0b11100 => .@"amomaxu.w",
                    else => return error.IllegalInstruction,
                },
                0b1 => switch (funct7_top5) { // double-word-size operations
                    0b00000 => .@"amoadd.d",
                    0b00001 => .@"amoswap.d",
                    0b00010 => .@"lr.d",
                    0b00011 => .@"sc.d",
                    0b00100 => .@"amoxor.d",
                    0b01000 => .@"amoor.d",
                    0b01100 => .@"amoand.d",
                    0b10000 => .@"amomin.d",
                    0b10100 => .@"amomax.d",
                    0b11000 => .@"amominu.d",
                    0b11100 => .@"amomaxu.d",
                    else => return error.IllegalInstruction,
                },
            };
            if ((op == .@"lr.w" or op == .@"lr.d") and rs2 != 0) return error.IllegalInstruction;
            return Instruction{ .AMO = .{ .opcode = op, .rs1 = rs1, .rs2 = rs2, .rd = rd } };
        },
        0b01100 => { // R-type instructions
            const mask: u7 = 0b101_1110;
            if (funct7 & mask != 0) return error.IllegalInstruction;
            const funct7_bit1: u1 = @truncate(funct7);
            const funct7_bit6: u1 = @truncate(funct7 >> 5);
            // pack bits 1 and 6 of funct7 and funct3 together
            const funct7_bits61_funct3: u5 = @as(u5, funct7_bit6) << 4 | @as(u5, funct7_bit1) << 3 | funct3;
            const op: Opcode.R = switch (funct7_bits61_funct3) {
                0b0_0_000 => .add,
                0b1_0_000 => .sub,
                0b0_0_001 => .sll,
                0b0_0_010 => .slt,
                0b0_0_011 => .sltu,
                0b0_0_100 => .xor,
                0b0_0_101 => .srl,
                0b1_0_101 => .sra,
                0b0_0_110 => .@"or",
                0b0_0_111 => .@"and",
                0b0_1_000 => .mul,
                0b0_1_001 => .mulh,
                0b0_1_010 => .mulhsu,
                0b0_1_011 => .mulhu,
                0b0_1_100 => .div,
                0b0_1_101 => .divu,
                0b0_1_110 => .rem,
                0b0_1_111 => .remu,
                else => return error.IllegalInstruction,
            };
            return Instruction{ .R = .{ .opcode = op, .rs1 = rs1, .rs2 = rs2, .rd = rd } };
        },
        0b01101 => { // lui
            const imm = u_type_immediate(bits);
            return Instruction{ .U = .{ .opcode = .lui, .rd = rd, .imm = imm } };
        },
        0b01110 => { // word-size R-type instructions
            const mask: u7 = 0b101_1110;
            if (funct7 & mask != 0) return error.IllegalInstruction;
            const funct7_bit1: u1 = @truncate(funct7);
            const funct7_bit6: u1 = @truncate(funct7 >> 5);
            // pack bits 1 and 6 of funct7 and funct3 together
            const funct7_bits61_funct3: u5 = @as(u5, funct7_bit6) << 4 | @as(u5, funct7_bit1) << 3 | funct3;
            const op: Opcode.R = switch (funct7_bits61_funct3) {
                0b0_0_000 => .addw,
                0b1_0_000 => .subw,
                0b0_0_001 => .sllw,
                0b0_0_101 => .srlw,
                0b1_0_101 => .sraw,
                0b0_1_000 => .mulw,
                0b0_1_100 => .divw,
                0b0_1_101 => .divuw,
                0b0_1_110 => .remw,
                0b0_1_111 => .remuw,
                else => return error.IllegalInstruction,
            };
            return Instruction{ .R = .{ .opcode = op, .rs1 = rs1, .rs2 = rs2, .rd = rd } };
        },
        0b11000 => { // B-type intructions: beq, bne, blt, bge, bltu, bgeu
            const imm = b_type_immediate(bits);
            const op: Opcode.B = switch (funct3) {
                0b000 => .beq,
                0b001 => .bne,
                0b100 => .blt,
                0b101 => .bge,
                0b110 => .bltu,
                0b111 => .bgeu,
                else => return error.IllegalInstruction,
            };
            return Instruction{ .B = .{ .opcode = op, .rs1 = rs1, .rs2 = rs2, .imm = imm } };
        },
        0b11001 => { // jalr
            if (funct3 != 0b000) return error.IllegalInstruction;
            const imm = i_type_immediate(bits);
            return Instruction{ .I = .{ .opcode = .jalr, .rs1 = rs1, .rd = rd, .imm = imm } };
        },
        0b11011 => { // jal
            const imm = j_type_immediate(bits);
            return Instruction{ .J = .{ .opcode = .jal, .rd = rd, .imm = imm } };
        },
        0b11100 => {
            if (funct3 != 0b000) { // csr opcodes
                const csrno: u12 = i_type_immediate(bits);
                const op: Opcode.CSR = switch (funct3) {
                    0b000 => unreachable,
                    0b001 => .csrrw,
                    0b010 => .csrrs,
                    0b011 => .csrrc,
                    0b100 => return error.IllegalInstruction,
                    0b101 => .csrrwi,
                    0b110 => .csrrsi,
                    0b111 => .csrrci,
                };
                return Instruction{ .CSR = .{ .opcode = op, .rs1 = rs1, .rd = rd, .csrno = csrno } };
            } else { // other system opcodes
                if (rd != 0) return error.IllegalInstruction;
                if (funct7 == 0b0001001) { // sfence.vma
                    // TODO: save rs1, rs2
                    return Instruction{ .Special = .@"sfence.vma" };
                }
                if (rs1 != 0) return error.IllegalInstruction;
                const @"bits31:20": u25 = @truncate(bits >> 20);
                const op: Opcode.Special = switch (@"bits31:20") {
                    0b000000000000 => .ecall,
                    0b000000000001 => .ebreak,
                    0b000100000010 => .sret,
                    0b001100000010 => .mret,
                    0b000100000101 => .wfi,
                    else => return error.IllegalInstruction,
                };
                return Instruction{ .Special = op };
            }
        },
        else => return error.IllegalInstruction,
    }
}
