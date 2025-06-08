// NS8250 UART
// http://byterunner.com/16550.html

const riscv = @import("../riscv.zig");
const Hart = @import("../hart.zig");
const PLIC = @import("plic.zig");
const std = @import("std");
const Mutex = std.Thread.Mutex;
const Condition = std.Thread.Condition;

const UART = @This();

rbr: ?u8, // received byte value
ier: struct { // interrupt enable register
    rx_avail: bool, // interrupt on byte available to read
    tx_avail: bool, // interrupt on byte available to transmit
},
iir: ?enum {
    rx_avail, // interrupt caused by byte available to read
    tx_avail, // interrupt caused by byte available to transmit
},
ipending: struct {
    tx_avail: bool,
},
// fcr not implemented (does not exist)
lcr: struct {
    dl_enable: bool,
},
scr: u8, // scratch register
// mcr, msr not implemented (read-only 0)
// dll, dlm not implemented, but we honour the dll/dlm enable bit

mutex: Mutex,
cond: Condition,

// interrupt controller through which to route the interrupt
interrupt_target: *PLIC,
// interrupt number on the interrupt controller
const interrupt_num = 1;

const reg_rbr_thr = 0x0;
const reg_ier = 0x1;
const reg_iir_fcr = 0x2;
const reg_lcr = 0x3;
const reg_mcr = 0x4;
const reg_lsr = 0x5;
const reg_msr = 0x6;
const reg_scr = 0x7;

pub const mmio_len = 0x8;

pub fn mmio_reg_read(uart: *UART, comptime T: type, reg_addr: u64) ?T {
    uart.mutex.lock();
    defer uart.mutex.unlock();
    if (comptime T != u8) return null;
    switch (reg_addr) {
        reg_rbr_thr => {
            defer uart.cond.signal();
            defer uart.update_interrupts();
            if (uart.lcr.dl_enable) return 0;
            // read any received byte
            defer uart.rbr = null;
            return if (uart.rbr) |byte| byte else 0;
        },
        reg_ier => { // read ier
            if (uart.lcr.dl_enable) return 0;
            return set_bit(uart.ier.rx_avail, 0) | set_bit(uart.ier.tx_avail, 1);
        },
        reg_iir_fcr => { // read iir
            // reading iir causes tx available interrupt to be cleared
            uart.ipending.tx_avail = false;
            if (uart.iir == null) return 0b1;
            defer uart.update_interrupts();
            return switch (uart.iir.?) {
                .tx_avail => 0b010,
                .rx_avail => 0b100,
            };
        },
        reg_lcr => { // read lcr
            return 0b11 | set_bit(uart.lcr.dl_enable, 7);
        },
        reg_mcr => return 0, // not implemented
        reg_lsr => {
            // available data sets bit 0, transmission available sets bits 5 and 6
            return set_bit(uart.rbr != null, 0) | set_bit(true, 5) | set_bit(true, 6);
        },
        reg_msr => return 0, // not implemented
        reg_scr => return uart.scr,
        else => unreachable,
    }
}

pub fn mmio_reg_write(uart: *UART, comptime T: type, reg_addr: u64, v: T) ?void {
    uart.mutex.lock();
    defer uart.mutex.unlock();
    if (comptime T != u8) return null;
    switch (reg_addr) {
        reg_rbr_thr => {
            if (uart.lcr.dl_enable) return; // ignore writes to dll
            const buf: [1]u8 = .{v};
            _ = std.posix.write(1, buf[0..1]) catch {};
            uart.ipending.tx_avail = true;
            uart.update_interrupts();
        },
        reg_ier => { // write ier
            if (uart.lcr.dl_enable) return; // ignore writes to dlm
            uart.ier.rx_avail = get_bit(v, 0);
            uart.ier.tx_avail = get_bit(v, 1);
            uart.update_interrupts();
        },
        reg_iir_fcr => return, // ignore writes to fcr, not implemented
        reg_lcr => { // write to lcr, only store dll/dlm enable bit
            uart.lcr.dl_enable = get_bit(v, 7);
        },
        reg_mcr => return, // ignore, not implemented
        reg_lsr => return, // ignore, read-only register
        reg_msr => return, // ignore, not implemented
        reg_scr => uart.scr = v,
        else => unreachable,
    }
    return;
}

fn update_interrupts(uart: *UART) void {
    if (uart.ier.tx_avail and uart.ipending.tx_avail) {
        uart.iir = .tx_avail;
        uart.interrupt_target.set_interrupt_pending(interrupt_num, true);
        return;
    }
    if (uart.ier.rx_avail and uart.rbr != null) {
        uart.iir = .rx_avail;
        uart.interrupt_target.set_interrupt_pending(interrupt_num, true);
        return;
    }
    uart.iir = null;
    uart.interrupt_target.set_interrupt_pending(interrupt_num, false);
}

pub fn task(uart: *UART) void {
    while (true) {
        uart.mutex.lock();
        if (uart.rbr != null) {
            uart.cond.wait(&uart.mutex);
        }
        uart.mutex.unlock();
        if (uart.rbr != null) continue;
        var rx: [1]u8 = undefined;
        const n = std.posix.read(0, rx[0..1]) catch 0;
        if (n != 0) {
            uart.mutex.lock();
            defer uart.mutex.unlock();
            uart.rbr = rx[0];
            uart.update_interrupts();
        }
    }
}

pub fn create() UART {
    return UART{
        .interrupt_target = undefined,
        .rbr = null,
        .ier = .{
            .rx_avail = false,
            .tx_avail = false,
        },
        .ipending = .{
            .tx_avail = false,
        },
        .iir = null,
        .lcr = .{
            .dl_enable = false,
        },
        .scr = 0,
        .mutex = Mutex{},
        .cond = Condition{},
    };
}

inline fn get_bit(v: u8, bit: u3) bool {
    return ((v >> bit) & 0b1) != 0;
}

inline fn set_bit(v: bool, bit: u3) u8 {
    return @as(u8, @intFromBool(v)) << bit;
}
