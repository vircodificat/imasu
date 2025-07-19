// the CLINT is a timer device that delivers timer and software interrupts
// https://www.kernel.org/doc/Documentation/devicetree/bindings/timer/sifive%2Cclint.yaml
// https://sifive.cdn.prismic.io/sifive%2Fc89f6e5a-cf9e-44c3-a3db-04420702dcc1_sifive+e31+manual+v19.08.pdf

const riscv = @import("../riscv.zig");
const Hart = @import("../hart.zig");
const std = @import("std");
const Timer = std.time.Timer;
const Mutex = std.Thread.Mutex;
const Condition = std.Thread.Condition;

const CLINT = @This();

mtimecmp: u64, // timer compare value

hart: *Hart, // hart that this CLINT interrupts

// thread variables
mutex: Mutex,
cond: Condition,

const reg_mswi = 0x0; // 4 bytes, lowest bit is target hart's msip bit
const reg_mtime = 0xbff8; // 8 bytes, reads value of the timer
const reg_mtimecmp = 0x4000; // 8 bytes, comparison value of the timer

pub const mmio_len = 0xc000;

pub const timebase_freq = std.time.us_per_s;

pub fn system_mtime() u64 {
    return @bitCast(std.time.microTimestamp());
}

pub fn mmio_reg_read(
    clint: *CLINT,
    comptime T: type,
    reg_addr: u64,
) ?T {
    switch (T) {
        u64 => switch (reg_addr) {
            // 8-byte access allowed to mtime and mtimecmp only
            reg_mtime => return system_mtime(),
            reg_mtimecmp => return clint.mtimecmp,
            else => return null,
        },
        u32 => switch (reg_addr) {
            // 4-byte access to all registers
            reg_mswi => {
                const msip = clint.hart.csrs.ip.msip;
                return @as(T, @intFromBool(msip));
            },
            reg_mtime => return @truncate(system_mtime()),
            reg_mtime + 4 => return @truncate(system_mtime() >> 32),
            reg_mtimecmp => return @truncate(clint.mtimecmp),
            reg_mtimecmp + 4 => return @truncate(clint.mtimecmp >> 32),
            else => return null,
        },
        else => return null,
    }
}

pub fn mmio_reg_write(
    clint: *CLINT,
    comptime T: type,
    reg_addr: u64,
    v: T,
) ?void {
    clint.mutex.lock();
    defer clint.mutex.unlock();
    switch (T) {
        u64 => switch (reg_addr) {
            reg_mtimecmp => {
                clint.mtimecmp = v;
                clint.cond.signal();
            },
            else => return null,
        },
        u32 => switch (reg_addr) {
            reg_mswi => {
                const swi = v & 0b1 == 0b1;
                clint.hart.set_interrupt_pending(.MachineSoftware, swi);
                clint.cond.signal();
            },
            reg_mtime, reg_mtime + 4 => return null,
            reg_mtimecmp => {
                clint.mtimecmp = (clint.mtimecmp & mask_hi) | v;
                clint.cond.signal();
            },
            reg_mtimecmp + 4 => {
                clint.mtimecmp = (clint.mtimecmp & mask_lo) | @as(u64, v) << 32;
                clint.cond.signal();
            },
            else => return null,
        },
        else => return null,
    }
}

// CLINT thread task
pub fn task(clint: *CLINT) void {
    while (true) {
        clint.mutex.lock();
        defer clint.mutex.unlock();

        // update interrupt bit
        const mtime: u64 = system_mtime();
        clint.hart.set_interrupt_pending(
            .MachineTimer,
            mtime > clint.mtimecmp,
        );

        if (mtime > clint.mtimecmp) {
            // if the timer has overrun, put the thread to sleep
            clint.cond.wait(&clint.mutex);
            continue;
        }
        // put the thread to sleep until we reach the next timer interrupt,
        // or one of the registers is written to, waking the thread back up
        // to recalcuate
        const delta_us = clint.mtimecmp - mtime;
        const delta_ns = delta_us *| std.time.ns_per_us;
        clint.cond.timedWait(&clint.mutex, delta_ns) catch {};
    }
}

pub fn create() CLINT {
    return CLINT{
        .hart = undefined,
        .mtimecmp = 0,
        .mutex = Mutex{},
        .cond = Condition{},
    };
}

const mask_lo: u64 = 0xffffffff;
const mask_hi: u64 = ~(@as(u64, 0xffffffff));
