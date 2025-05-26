// the CLINT is a timer device that delivers timer and software interrupts
// https://www.kernel.org/doc/Documentation/devicetree/bindings/timer/sifive%2Cclint.yaml
// https://sifive.cdn.prismic.io/sifive%2Fc89f6e5a-cf9e-44c3-a3db-04420702dcc1_sifive+e31+manual+v19.08.pdf

const riscv = @import("../riscv.zig");
const Exception = riscv.Exception;
const Hart = @import("../hart.zig");
const std = @import("std");
const Timer = std.time.Timer;
const Mutex = std.Thread.Mutex;
const Condition = std.Thread.Condition;

const CLINT = @This();

mtimecmp: u64, // timer compare value

interrupt_target: *Hart, // hart that this CLINT interrupts

// thread variables
mutex: Mutex,
cond: Condition,

const reg_mswi = 0x0; // 4 bytes, lowest bit is target hart's msip bit
const reg_mtime = 0xbff8; // 8 bytes, reads value of the timer
const reg_mtimecmp = 0x4000; // 8 bytes, comparison value of the timer

pub const mmio_len = 0xc000;

pub const timebase_freq = std.time.ns_per_s;

pub fn system_mtime() u64 {
    return @truncate(@as(u128, @bitCast(std.time.nanoTimestamp())));
}

pub fn mmio_reg_read(
    clint: *CLINT,
    comptime T: type,
    reg_addr: u64,
) Exception!T {
    switch (T) {
        u64 => switch (reg_addr) {
            // 8-byte access allowed to mtime and mtimecmp only
            reg_mtime => return system_mtime(),
            reg_mtimecmp => return clint.mtimecmp,
            else => return Exception.LoadAccessFault,
        },
        u32 => switch (reg_addr) {
            // 4-byte access to all registers
            reg_mswi => return @as(T, @intFromBool(clint.interrupt_target.csrs.ip.msip)),
            reg_mtime => return @truncate(system_mtime()),
            reg_mtime + 4 => return @truncate(system_mtime() >> 32),
            reg_mtimecmp => return @truncate(clint.mtimecmp),
            reg_mtimecmp + 4 => return @truncate(clint.mtimecmp >> 32),
            else => return Exception.LoadAccessFault,
        },
        else => return Exception.LoadAccessFault,
    }
}

pub fn mmio_reg_write(
    clint: *CLINT,
    comptime T: type,
    reg_addr: u64,
    v: T,
) Exception!void {
    clint.cond.signal();
    clint.mutex.lock();
    defer clint.mutex.unlock();
    errdefer clint.mutex.unlock();
    const mask_lo: u64 = 0xffffffff;
    const mask_hi: u64 = ~mask_lo;
    switch (T) {
        u64 => switch (reg_addr) {
            reg_mtimecmp => clint.mtimecmp = v,
            else => return Exception.StoreAccessFault,
        },
        u32 => switch (reg_addr) {
            reg_mswi => clint.interrupt_target.set_interrupt_pending(.MachineSoftware, v & 0b1 == 0b1),
            reg_mtime, reg_mtime + 4 => return Exception.StoreAccessFault,
            reg_mtimecmp => clint.mtimecmp = (clint.mtimecmp & mask_hi) | v,
            reg_mtimecmp + 4 => clint.mtimecmp = (clint.mtimecmp & mask_lo) | @as(u64, v) << 32,
            else => return Exception.StoreAccessFault,
        },
        else => return Exception.StoreAccessFault,
    }
}

// CLINT thread task
pub fn task(clint: *CLINT) void {
    while (true) {
        clint.mutex.lock();
        defer clint.mutex.unlock();

        const mtime: u64 = system_mtime();
        clint.interrupt_target.set_interrupt_pending(
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
        const delta = clint.mtimecmp - mtime;
        clint.cond.timedWait(&clint.mutex, delta) catch {};
    }
}

pub fn create() CLINT {
    return CLINT{
        .interrupt_target = undefined,
        .mtimecmp = 0,
        .mutex = Mutex{},
        .cond = Condition{},
    };
}
