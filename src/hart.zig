// RISC-V Hart

const Instruction = @import("instruction.zig").Instruction;
const Exception = @import("exception.zig").Exception;
const Privilege = @import("priv.zig").Privilege;
const Memory = @import("memory.zig");
const CSRs = @import("csr.zig");
const decode = @import("decode.zig");
const debug = @import("debug.zig");
const std = @import("std");
const assert = std.debug.assert;

const Hart = @This();

pub const xlen = u64; // integer register width
// hart state:
x: [32]xlen, // general purpose registers
pc: xlen, // program counter
csrs: CSRs, // control and status registers
priv: Privilege, // privilege level
res: ?struct { // reservation set for lr/sc
    addr: xlen, // address
    double: bool, // reservation is for a double or word
},

mem: *Memory, // handle to main memory

pub fn create() Hart {
    return Hart{
        .x = .{0} ** 32,
        .pc = Memory.mem_base,
        .csrs = CSRs.create(),
        .priv = .M,
        .res = null,
        .mem = undefined,
    };
}

// lower word of register
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

// perform a fetch-decode-execute cycle of the hart
pub fn step(hart: *Hart) void {
    // fetch instruction
    const inst_bits = hart.mem.fetch(hart.pc) catch |err| {
        // on instruction address misaligned or instruction fetch access/page fault,
        // store the faulting virtual address in xtval,
        // which is the value of the program counter
        @branchHint(.unlikely);
        hart.trap_on_exception(err, hart.pc);
        return;
    };
    // decode instruction
    const instruction = decode.instruction(inst_bits) catch |err| {
        // instruction decode can only fail with an illegal instruction exception,
        // so store the bits of the instruction in xtval
        @branchHint(.unlikely);
        hart.trap_on_exception(err, zext_to_xlen(inst_bits));
        return;
    };
    // execute instruction
    hart.execute(instruction) catch |err| {
        @branchHint(.unlikely);
        const xtval = switch (err) {
            // load/store exceptions store the faulty virtual address in xtval
            Exception.LoadMisaligned,
            Exception.StoreMisaligned,
            Exception.LoadAccessFault,
            Exception.StoreAccessFault,
            Exception.LoadPageFault,
            Exception.StorePageFault,
            => hart.faulty_virtual_addr(instruction),
            // illegal instruction exceptions store the bits of the faulty instruction
            Exception.IllegalInstruction => zext_to_xlen(inst_bits),
            // breakpoints store the faulty virtual address of the instruction (the pc)
            Exception.Breakpoint => hart.pc,
            // everything else is already handled or can be 0
            else => 0,
        };
        hart.trap_on_exception(err, xtval);
        return;
    };
}

// if instruction execution causes an exception related to an address, such as
// a load/store access fault/page fault/misaligned fault, then the trap value register
// is set to this faulting virtual address
fn faulty_virtual_addr(hart: *Hart, instruction: Instruction) xlen {
    return switch (instruction) {
        .AMO => |inst| hart.x[inst.rs1],
        .I => |inst| switch (inst.opcode) {
            .jalr => hart.x[inst.rs1] +% inst.imm & ~@as(xlen, 0b1),
            .lb, .lh, .lw, .ld, .lbu, .lhu, .lwu => hart.x[inst.rs1] +% inst.imm,
            else => unreachable,
        },
        .S => |inst| hart.x[inst.rs1] +% inst.imm,
        else => unreachable,
    };
}

// on an exception, the trap cause register is set to a value
// depending on the type of exception
fn exception_to_xcause_csr_value(err: Exception) xlen {
    return switch (err) {
        Exception.InstMisaligned => 0,
        Exception.InstAccessFault => 1,
        Exception.IllegalInstruction => 2,
        Exception.Breakpoint => 3,
        Exception.LoadMisaligned => 4,
        Exception.LoadAccessFault => 5,
        Exception.StoreMisaligned => 6,
        Exception.StoreAccessFault => 7,
        Exception.ECallUser => 8,
        Exception.ECallSupervisor => 9,
        Exception.ECallMachine => 11,
        Exception.InstPageFault => 12,
        Exception.LoadPageFault => 13,
        Exception.StorePageFault => 15,
    };
}

pub const InterruptSource = enum {
    Software,
    Timer,
    External,
};

// set the hart's interrupt pending bit for some source
pub fn assert_interrupt_pending(hart: *Hart, source: InterruptSource, v: bool) void {
    switch (source) {
        .Software => hart.csrs.mip.msip = v,
        .Timer => hart.csrs.mip.mtip = v,
        .External => hart.csrs.mip.meip = v,
    }
}

// try to take a trap caused by an interrupt
pub fn try_take_interrupt(hart: *Hart) void {
    // if the global mie bit is disabled, do not take any interrupts
    if (hart.csrs.mstatus.mie == false) return;
    // check for and take external interrupts
    if (hart.csrs.mip.meip and hart.csrs.mie.meie) {
        hart.trap_on_interrupt(.External);
        return;
    }
    // check for and take software interrupts
    if (hart.csrs.mip.msip and hart.csrs.mie.msie) {
        hart.trap_on_interrupt(.Software);
        return;
    }
    // check for and take timer interrupts
    if (hart.csrs.mip.mtip and hart.csrs.mie.mtie) {
        hart.trap_on_interrupt(.Timer);
        return;
    }
}

// take a trap caused by an interrupt
fn trap_on_interrupt(hart: *Hart, source: InterruptSource) void {
    assert(hart.csrs.mstatus.mie == true);
    const xcause_exception_code: xlen = switch (source) {
        .Software => 3,
        .Timer => 7,
        .External => 11,
    };
    // push mie to mpie, mie becomes false
    hart.csrs.mstatus.mpie = hart.csrs.mstatus.mie;
    hart.csrs.mstatus.mie = false;
    // push current privilege to mpp, privilege becomes M-mode
    hart.csrs.mstatus.mpp = hart.priv;
    hart.priv = .M;
    // mtval is set to 0
    hart.csrs.mtval = 0;
    // mcause most significant bit is set to 1 to indicate interrupt
    // and also set the exception code to the right interrupt
    hart.csrs.mcause = @as(xlen, 1 << 63) | xcause_exception_code;
    // store pc into mepc, set pc to trap vector
    // as this is an interrupt, set pc based on whether mtvec is direct or vectored
    hart.csrs.mepc = hart.pc;
    hart.pc = hart.csrs.mtvec.base;
    if (hart.csrs.mtvec.vectored) hart.pc +%= 4 * xcause_exception_code;
    return;
}

// take a trap caused by an exception
fn trap_on_exception(hart: *Hart, err: Exception, xtval: xlen) void {
    // TODO: S-mode delegation when S-mode is implemented

    // push mie to mpie, mie becomes false
    hart.csrs.mstatus.mpie = hart.csrs.mstatus.mie;
    hart.csrs.mstatus.mie = false;
    // push current privilege to mpp, privilege becomes M-mode
    hart.csrs.mstatus.mpp = hart.priv;
    hart.priv = .M;
    // store exception cause and value
    hart.csrs.mtval = xtval;
    hart.csrs.mcause = exception_to_xcause_csr_value(err);
    // store pc into mepc, set pc to trap vector base
    // as this is the trap procedure for exceptions not interrupts,
    // we always go to the base address
    hart.csrs.mepc = hart.pc;
    hart.pc = hart.csrs.mtvec.base;
    return;
}

// perform 'mret'
fn mret(hart: *Hart) !void {
    if (hart.priv != .M) return error.IllegalInstruction;
    if (hart.csrs.mstatus.mpp == .S) unreachable;
    // pop privilege from mpp, mpp becomes lowest privilege level
    hart.priv = hart.csrs.mstatus.mpp;
    hart.csrs.mstatus.mpp = .U;
    // pop mpie to mie, mpie becomes set
    hart.csrs.mstatus.mie = hart.csrs.mstatus.mpie;
    hart.csrs.mstatus.mpie = true;
    // set the program counter to mepc
    hart.pc = hart.csrs.mepc;
    return;
}

fn execute(hart: *Hart, instruction: Instruction) Exception!void {
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
                .srlw => sext_to_xlen(word(x_rs1) >> shamt5),
                .sra => unsigned(signed(x_rs1) >> shamt6),
                .sraw => sext_to_xlen(signed(word(x_rs1)) >> shamt5),
                .@"or" => x_rs1 | x_rs2,
                .@"and" => x_rs1 & x_rs2,
                // M-extension
                .mul => x_rs1 *% x_rs2,
                .mulw => sext_to_xlen(word(x_rs1) *% word(x_rs2)),
                .mulh => mulh(x_rs1, x_rs2),
                .mulhsu => mulhsu(x_rs1, x_rs2),
                .mulhu => mulhu(x_rs1, x_rs2),
                .div => div(x_rs1, x_rs2),
                .divw => sext_to_xlen(divw(word(x_rs1), word(x_rs2))),
                .divu => divu(x_rs1, x_rs2),
                .divuw => sext_to_xlen(divuw(word(x_rs1), word(x_rs2))),
                .rem => rem(x_rs1, x_rs2),
                .remw => sext_to_xlen(remw(word(x_rs1), word(x_rs2))),
                .remu => if (x_rs2 == 0) x_rs1 else x_rs1 % x_rs2,
                .remuw => sext_to_xlen(
                    if (word(x_rs2) == 0) word(x_rs1) else word(x_rs1) % word(x_rs2),
                ),
            };
            hart.pc +%= 4;
            return;
        },
        .AMO => |inst| {
            // atomic instructions are not performed atomically
            // as there is only one hart executing instructions
            const x_rs1 = hart.x[inst.rs1];
            const x_rs2 = hart.x[inst.rs2];
            const result: xlen = switch (inst.opcode) {
                .@"lr.w" => lrw: {
                    defer hart.res = .{ .addr = x_rs1, .double = false };
                    break :lrw sext_to_xlen(try hart.mem.load_word(x_rs1));
                },
                .@"lr.d" => lrd: {
                    defer hart.res = .{ .addr = x_rs1, .double = true };
                    break :lrd try hart.mem.load_double(x_rs1);
                },
                .@"sc.w" => scw: {
                    defer hart.res = null;
                    errdefer hart.res = null;
                    if (hart.res) |res| {
                        if ((x_rs1 == res.addr) or (res.double and x_rs1 == res.addr + 4)) {
                            try hart.mem.store_word(x_rs1, word(x_rs2));
                            break :scw 0; // success
                        }
                    }
                    break :scw 1; // fail
                },
                .@"sc.d" => scd: {
                    defer hart.res = null;
                    errdefer hart.res = null;
                    if (hart.res) |res| {
                        if (res.double and x_rs1 == res.addr) {
                            try hart.mem.store_double(x_rs1, x_rs2);
                            break :scd 0; // success
                        }
                    }
                    break :scd 1; // fail
                },
                .@"amoswap.w",
                .@"amoadd.w",
                .@"amoxor.w",
                .@"amoand.w",
                .@"amoor.w",
                .@"amomin.w",
                .@"amomax.w",
                .@"amominu.w",
                .@"amomaxu.w",
                => |amo_w| amo_w: {
                    const load = try hart.mem.load_word(x_rs1);
                    const w_rs2 = word(x_rs2);
                    const store = switch (amo_w) {
                        .@"amoswap.w" => w_rs2,
                        .@"amoadd.w" => load +% w_rs2,
                        .@"amoxor.w" => load ^ w_rs2,
                        .@"amoand.w" => load & w_rs2,
                        .@"amoor.w" => load | w_rs2,
                        .@"amomin.w" => unsigned(@min(signed(load), signed(w_rs2))),
                        .@"amomax.w" => unsigned(@max(signed(load), signed(w_rs2))),
                        .@"amominu.w" => @min(load, w_rs2),
                        .@"amomaxu.w" => @max(load, w_rs2),
                        else => unreachable,
                    };
                    try hart.mem.store_word(x_rs1, store);
                    break :amo_w sext_to_xlen(load);
                },
                .@"amoswap.d",
                .@"amoadd.d",
                .@"amoxor.d",
                .@"amoand.d",
                .@"amoor.d",
                .@"amomin.d",
                .@"amomax.d",
                .@"amominu.d",
                .@"amomaxu.d",
                => |amo_d| amo_d: {
                    const load = try hart.mem.load_double(x_rs1);
                    const store = switch (amo_d) {
                        .@"amoswap.d" => x_rs2,
                        .@"amoadd.d" => load +% x_rs2,
                        .@"amoxor.d" => load ^ x_rs2,
                        .@"amoand.d" => load & x_rs2,
                        .@"amoor.d" => load | x_rs2,
                        .@"amomin.d" => unsigned(@min(signed(load), signed(x_rs2))),
                        .@"amomax.d" => unsigned(@max(signed(load), signed(x_rs2))),
                        .@"amominu.d" => @min(load, x_rs2),
                        .@"amomaxu.d" => @max(load, x_rs2),
                        else => unreachable,
                    };
                    try hart.mem.store_double(x_rs1, store);
                    break :amo_d load;
                },
            };
            if (inst.rd != 0) hart.x[inst.rd] = result;
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
                .jalr => {
                    const jump_target = x_rs1 +% imm & ~@as(xlen, 0b1);
                    if (inst.rd != 0) hart.x[inst.rd] = hart.pc +% 4;
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
                .srliw => sext_to_xlen(word(x_rs1) >> shamt5),
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
        .B => |inst| {
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
        .J => |inst| {
            const imm = sext_to_xlen(inst.imm) << 1;
            const jump_target = hart.pc +% imm;
            if (inst.rd != 0) hart.x[inst.rd] = hart.pc +% 4;
            hart.pc = jump_target;
            return;
        },
        .Special => |inst| {
            switch (inst) {
                .fence, .@"fence.i" => { // no-op
                    hart.pc +%= 4;
                    return;
                },
                .mret => {
                    try hart.mret();
                    return;
                },
                .wfi => { // no-op
                    hart.pc +%= 4;
                    return;
                },
                .ebreak => return Exception.Breakpoint,
                .ecall => return switch (hart.priv) {
                    .U => Exception.ECallUser,
                    .M => Exception.ECallMachine,
                    else => unreachable,
                },
                else => return Exception.IllegalInstruction,
            }
        },
    }
}

fn mulh(x_rs1: u64, x_rs2: u64) u64 {
    const v = @as(i128, signed(x_rs1)) *% @as(i128, signed(x_rs2));
    return @truncate(unsigned(v) >> 64);
}

fn mulhu(x_rs1: u64, x_rs2: u64) u64 {
    const v = @as(u128, x_rs1) *% @as(u128, x_rs2);
    return @truncate(v >> 64);
}

fn mulhsu(x_rs1: u64, x_rs2: u64) u64 {
    const sext_rs1 = @as(i128, signed(x_rs1));
    const v: u128 = unsigned(sext_rs1) *% @as(u128, x_rs2);
    return @truncate(v >> 64);
}

fn div(x_rs1: u64, x_rs2: u64) u64 {
    const s_rs1 = signed(x_rs1);
    const s_rs2 = signed(x_rs2);
    // division by 0
    if (s_rs2 == 0) {
        @branchHint(.unlikely);
        return unsigned(@as(i64, -1));
    }
    // divison overflow: intmin / -1
    if (s_rs1 == std.math.minInt(i64) and s_rs2 == -1) {
        @branchHint(.unlikely);
        return x_rs1;
    }
    // perform division
    return unsigned(@divTrunc(s_rs1, s_rs2));
}

fn divw(x_rs1: u32, x_rs2: u32) u32 {
    const s_rs1 = signed(x_rs1);
    const s_rs2 = signed(x_rs2);
    // division by 0
    if (s_rs2 == 0) {
        @branchHint(.unlikely);
        return unsigned(@as(i32, -1));
    }
    // divison overflow: intmin / -1
    if (s_rs1 == std.math.minInt(i32) and s_rs2 == -1) {
        @branchHint(.unlikely);
        return x_rs1;
    }
    // perform division
    return unsigned(@divTrunc(s_rs1, s_rs2));
}

fn divu(x_rs1: u64, x_rs2: u64) u64 {
    // division by 0
    if (x_rs2 == 0) {
        @branchHint(.unlikely);
        return std.math.maxInt(u64);
    }
    // perform division
    return @divTrunc(x_rs1, x_rs2);
}

fn divuw(x_rs1: u32, x_rs2: u32) u32 {
    // division by 0
    if (x_rs2 == 0) {
        @branchHint(.unlikely);
        return std.math.maxInt(u32);
    }
    // perform division
    return @divTrunc(x_rs1, x_rs2);
}

fn rem(x_rs1: u64, x_rs2: u64) u64 {
    const s_rs1 = signed(x_rs1);
    const s_rs2 = signed(x_rs2);
    // division by 0
    if (s_rs2 == 0) {
        @branchHint(.unlikely);
        return x_rs1;
    }
    // division overflow: intmin / -1
    if (s_rs1 == std.math.minInt(i64) and s_rs2 == -1) {
        @branchHint(.unlikely);
        return 0;
    }
    // perform remainder
    return if (s_rs2 < 0) unsigned(
        @rem(s_rs1, -s_rs2),
    ) else unsigned(
        @rem(s_rs1, s_rs2),
    );
}

fn remw(w_rs1: u32, w_rs2: u32) u32 {
    const s_rs1 = signed(w_rs1);
    const s_rs2 = signed(w_rs2);
    // division by 0
    if (s_rs2 == 0) {
        @branchHint(.unlikely);
        return w_rs1;
    }
    // division overflow: intmin / -1
    if (s_rs1 == std.math.minInt(i32) and s_rs2 == -1) {
        @branchHint(.unlikely);
        return 0;
    }
    // perform remainder
    return if (s_rs2 < 0) unsigned(
        @rem(s_rs1, -s_rs2),
    ) else unsigned(
        @rem(s_rs1, s_rs2),
    );
}
