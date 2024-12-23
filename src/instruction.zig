// RISC-V Instruction opcodes and operands

pub const Opcode = struct {
    // R-type instruction opcodes
    pub const R = enum {
        // RV32/64 I
        add, // add
        sub, // subtract
        sll, // shift left logical
        slt, // set less than
        sltu, // set less than unsigned
        xor, // logical xor
        srl, // shift right logical
        sra, // shift right arithmetic
        @"or", // logical or
        @"and", // logical and
        addw, // add word (RV64 only)
        subw, // sub word (RV64 only)
        sllw, // shift left logical word (RV64 only)
        srlw, // shift right logical word (RV64 only)
        sraw, // shift right arithmetic word (RV64 only)
        // RV32/64 M
        mul, // multiply
        mulh, // multiply, high bits
        mulhsu, // multiply signed by unsigned, high bits
        mulhu, // multiply unsigned by unsigned, high bits
        div, // divide
        divu, // divide unsigned
        rem, // remainder
        remu, // remainder unsigned
        mulw, // multiply word (RV64 only)
        divw, // divide word (RV64 only)
        divuw, // divide unsigned word (RV64 only)
        remw, // remainder word (RV64 only)
        remuw, // remainder unsigned word (RV64 only)
    };

    // Atomic memory operation instruction opcodes
    // These use the R-type encoding, with two 1-bit aq and rl fields
    pub const AMO = enum {
        // RV32/64 A
        @"lr.w", // load-reserved word
        @"sc.w", // store-conditional word
        @"amoswap.w", // atomic swap word
        @"amoadd.w", // atomic add word
        @"amoxor.w", // atomic xor word
        @"amoand.w", // atomic and word
        @"amoor.w", // atomic or word
        @"amomin.w", // atomic minimum word
        @"amomax.w", // atomic maximum word
        @"amominu.w", // atomic minimum unsigned word
        @"amomaxu.w", // atomic maximum unsigned word
        @"lr.d", // load-reserved double-word (RV64 only)
        @"sc.d", // store-conditional double-word (RV64 only)
        @"amoswap.d", // atomic swap double-word (RV64 only)
        @"amoadd.d", // atomic add double-word (RV64 only)
        @"amoxor.d", // atomic xor double-word (RV64 only)
        @"amoand.d", // atomic and double-word (RV64 only)
        @"amoor.d", // atomic or double-word (RV64 only)
        @"amomin.d", // atomic minimum double-word (RV64 only)
        @"amomax.d", // atomic maximum double-word (RV64 only)
        @"amominu.d", // atomic minimum unsigned double-word (RV64 only)
        @"amomaxu.d", // atomic maximum unsigned double-word (RV64 only)
    };

    // I-type instruction opcodes
    pub const I = enum {
        // RV32/64 I
        jalr, // jump and link register
        lb, // load byte
        lh, // load half-word
        lw, // load word
        ld, // load double-word (RV64 only)
        lbu, // load byte unsigned
        lhu, // load half-word unsigned
        lwu, // load word unsigned (RV64 only)
        addi, // add immediate
        addiw, // add immediate word (RV64 only)
        slti, // set less than immediate
        sltiu, // set less than immediate unsigned
        xori, // logical xor immediate
        ori, // logical or immediate
        andi, // logical and immediate
        slli, // shift left logical immediate
        slliw, // shift left logical immediate word (RV64 only)
        srli, // shift right logical immediate
        srliw, // shift right logical immediate word (RV64 only)
        srai, // shift right arithmetic immediate
        sraiw, // shift right arithmetic immediate word (RV64 only)
    };

    // Control and status register instruction opcodes
    // These use the I-type encoding
    pub const CSR = enum {
        // RV32/64 Zicsr
        csrrw, // CSR read and write
        csrrs, // CSR read and set bits
        csrrc, // CSR read and clear bits
        csrrwi, // CSR read and write immediate
        csrrsi, // CSR read and set bits immediate
        csrrci, // CSR read and clear bits immediate
    };

    // S-type instruction opcodes
    pub const S = enum {
        sb, // store byte
        sh, // store half-word
        sw, // store word
        sd, // store double-word (RV64 only)
    };

    // B-type instruction opcodes
    pub const B = enum {
        beq, // branch if equal
        bne, // branch if not equal
        blt, // branch if less than
        bge, // branch if greater than
        bltu, // branch if less than unsigned
        bgeu, // branch if greater than unsigned
    };

    // U-type instruction opcodes
    pub const U = enum {
        lui, // load upper immediate
        auipc, // add upper immediate to program counter
    };

    // J-type instruction opcodes
    pub const J = enum {
        jal, // jump and link
    };

    // Privileged and Miscellaneous instructions
    pub const Special = enum {
        fence, // memory fence
        @"fence.i", // instruction fence
        ecall, // environment call
        ebreak, // breakpoint
        mret, // return from machine mode
        sret, // return from supervisor mode
        wfi, // wait for interrupt
        @"sfence.vma", // supervisor fence virtual memory access
    };
};

pub const Instruction = union(enum) {
    // R-type instructions have 2 source register operands
    // and a register destination operand
    R: struct {
        opcode: Opcode.R,
        rs1: u5,
        rs2: u5,
        rd: u5,
    },
    // AMO instructions
    AMO: struct {
        opcode: Opcode.AMO,
        rs1: u5,
        rs2: u5,
        rd: u5,
    },
    // I-type instructions have a source and destination register operand
    // and a 12-bit signed immediate value
    I: struct {
        opcode: Opcode.I,
        rs1: u5,
        rd: u5,
        imm: i12,
    },
    CSR: struct {
        opcode: Opcode.CSR,
        rs1: u5,
        rd: u5,
        csrno: u12,
    },
    // S-type instructions have two source register operands
    // and a 12-bit signed immediate value
    S: struct {
        opcode: Opcode.S,
        rs1: u5,
        rs2: u5,
        imm: i12,
    },
    // B-type instructions have two source register operands
    // and a 13-bit signed even immediate value (least significant bit is 0)
    B: struct {
        opcode: Opcode.B,
        rs1: u5,
        rs2: u5,
        imm: i13,
    },
    // U-type instructions have a destination register operand
    // and a 32-bit signed immediate value with the least significant 12 bits all 0s
    U: struct {
        opcode: Opcode.U,
        rd: u5,
        imm: i32,
    },
    // J-type instructions have a destination register operand
    // and a 21-bit signed even immediate value (least significatn bit is 0)
    J: struct {
        opcode: Opcode.J,
        rd: u5,
        imm: i21,
    },
    // Privileged and Miscellaneous instructions
    Special: Opcode.Special,
};

const testing = @import("std").testing;

fn num_variants(T: anytype) usize {
    return @typeInfo(T).@"enum".fields.len;
}

test "enumerated all instructions" {
    // 10 RV32I + 5 RV64I only + 8 RV32M + 5 RV64M only
    try testing.expect(num_variants(Opcode.R) == 10 + 5 + 8 + 5);
    // lr sc + 9 operations for word and double-word size
    try testing.expect(num_variants(Opcode.AMO) == 2 * 11);
    // 15 RV32I + 6 RV64 only
    try testing.expect(num_variants(Opcode.I) == 15 + 6);
    // write, set bits, clear bits, with register and immediate
    try testing.expect(num_variants(Opcode.CSR) == 6);
    // stores for powers of 2 bytes up to 8
    try testing.expect(num_variants(Opcode.S) == 3 + 1);
    // 6 branch predicates
    try testing.expect(num_variants(Opcode.B) == 6);
    // lui and auipc
    try testing.expect(num_variants(Opcode.U) == 2);
    // jal only
    try testing.expect(num_variants(Opcode.J) == 1);
    try testing.expect(num_variants(Opcode.Special) == 8);
}
