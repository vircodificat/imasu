// the CLINT is a timer device that delivers timer and software interrupts
// https://www.kernel.org/doc/Documentation/devicetree/bindings/timer/sifive%2Cclint.yaml
// https://sifive.cdn.prismic.io/sifive%2Fc89f6e5a-cf9e-44c3-a3db-04420702dcc1_sifive+e31+manual+v19.08.pdf

const Exception = @import("../exception.zig").Exception;
const Hart = @import("../hart.zig");
const std = @import("std");
const Timer = std.time.Timer;
const Mutex = std.Thread.Mutex;
const Condition = std.Thread.Condition;

const CLINT = @This();

mtime: u64, // timer value
mtimecmp: u64, // timer compare value

timer: Timer,
interrupt_target: *Hart, // hart that this CLINT interrupts

mutex: Mutex,
cond: Condition,

const reg_mswi = 0x0; // 4 bytes, lowest bit reads/writes target hart's msip bit
const reg_mtime = 0xbff8; // 8 bytes, reads value of the timer
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
            reg_mswi => return @as(T, @intFromBool(clint.interrupt_target.csrs.mip.msip)),
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
    clint.cond.signal(); // wake the sleeping CLINT thread
    clint.mutex.lock(); // acquire mutex which we then release
    defer clint.mutex.unlock();
    errdefer clint.mutex.unlock();
    switch (T) {
        u64 => switch (reg_addr) {
            reg_mtimecmp => clint.mtimecmp = v,
            else => return Exception.StoreAccessFault,
        },
        u32 => switch (reg_addr) {
            reg_mswi => clint.interrupt_target.set_interrupt_pending(.Software, v & 0b1 == 0b1),
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

        // run the timer by incrementing mtime, and checking against mtimecmp
        // to set the mtip bit
        const tick = clint.timer.lap();
        clint.mtime += tick;
        clint.interrupt_target.set_interrupt_pending(.Timer, clint.mtime > clint.mtimecmp);

        if (clint.mtimecmp < clint.mtime) continue;
        // if the difference between now and mtimecmp is above some threshold,
        // put the thread to sleep until we reach that time, or one of the registers
        // is written to, waking the thread back up
        const delta_ns = clint.mtimecmp - clint.mtime;
        if (delta_ns > 10 * std.time.ns_per_us) {
            clint.cond.timedWait(&clint.mutex, delta_ns) catch {};
        }
    }
}

pub fn create() CLINT {
    return CLINT{
        .interrupt_target = undefined,
        .mtime = 0,
        .mtimecmp = 0,
        .timer = undefined,
        .mutex = Mutex{},
        .cond = Condition{},
    };
}
