// the CLINT is a timer device that delivers timer and software interrupts
// https://www.kernel.org/doc/Documentation/devicetree/bindings/timer/sifive%2Cclint.yaml
// https://sifive.cdn.prismic.io/sifive%2Fc89f6e5a-cf9e-44c3-a3db-04420702dcc1_sifive+e31+manual+v19.08.pdf

const Exception = @import("../exception.zig").Exception;
const Hart = @import("../hart.zig");
const std = @import("std");
const Timer = std.time.Timer;

const CLINT = @This();

mtime: u64, // timer value
mtimecmp: u64, // timer compare value

timer: Timer,
interrupt_target: *Hart, // hart that this CLINT interrupts

const reg_mswi = 0x0; // 4 bytes, lowest bit reads/writes target hart's msip bit
const reg_mtime = 0xbff8; // 8 bytes, reads/writes value of the timer
const reg_mtimecmp = 0x4000; // 8 bytes, reads/writes comparion value of the timer

pub const mmio_len = 0xc000;

const mask_lo: u64 = 0xffffffff;
const mask_hi: u64 = ~mask_lo;

pub fn mmio_reg_read(clint: *CLINT, comptime T: type, reg_addr: u64) !T {
    switch (T) {
        u64 => switch (reg_addr) { // 8-byte access to mtime and mtimecmp only
            reg_mtime => return clint.mtime,
            reg_mtimecmp => return clint.mtimecmp,
            else => return Exception.LoadAccessFault,
        },
        u32 => switch (reg_addr) { // 4-byte access to all registers
            reg_mswi => {
                const msip = clint.interrupt_target.csrs.mip.msip;
                return @as(T, @intFromBool(msip));
            },
            reg_mtime => return @truncate(clint.mtime),
            reg_mtime + 4 => return @truncate(clint.mtime >> 32),
            reg_mtimecmp => return @truncate(clint.mtimecmp),
            reg_mtimecmp + 4 => return @truncate(clint.mtimecmp >> 32),
            else => return Exception.LoadAccessFault,
        },
        else => return Exception.LoadAccessFault,
    }
}

pub fn mmio_reg_write(clint: *CLINT, comptime T: type, reg_addr: u64, v: T) !void {
    switch (T) {
        u64 => switch (reg_addr) {
            reg_mtime => {
                clint.mtime = v;
                clint.timer_check();
            },
            reg_mtimecmp => {
                clint.mtimecmp = v;
                clint.timer_check();
            },
            else => return Exception.StoreAccessFault,
        },
        u32 => switch (reg_addr) {
            reg_mswi => {
                clint.interrupt_target.assert_interrupt_pending(.Software, v & 0b1 == 0b1);
            },
            reg_mtime => {
                clint.mtime = (clint.mtime & mask_hi) | v;
                clint.timer_check();
            },
            reg_mtime + 4 => {
                clint.mtime = (clint.mtime & mask_lo) | @as(u64, v) << 32;
                clint.timer_check();
            },
            reg_mtimecmp => {
                clint.mtimecmp = (clint.mtimecmp & mask_hi) | v;
                clint.timer_check();
            },
            reg_mtimecmp + 4 => {
                clint.mtimecmp = (clint.mtimecmp & mask_lo) | @as(u64, v) << 32;
                clint.timer_check();
            },
            else => return Exception.StoreAccessFault,
        },
        else => return Exception.StoreAccessFault,
    }
}

// increment the timer value and check whether to assert/deassert an interrupt
pub fn run(clint: *CLINT) void {
    const delta = clint.timer.lap();
    clint.mtime += delta;
    clint.timer_check();
}

// if mtime > mtimecmp, assert an interrupt
fn timer_check(clint: *const CLINT) void {
    clint.interrupt_target.set_interrupt_pending(.Timer, clint.mtime > clint.mtimecmp);
}

pub fn create() CLINT {
    return CLINT{
        .interrupt_target = undefined,
        .mtime = 0,
        .mtimecmp = 0,
        .timer = undefined,
    };
}
