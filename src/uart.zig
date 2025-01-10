// NS8250 UART

// http://byterunner.com/16550.html

const Exception = @import("exception.zig").Exception;
const Hart = @import("hart.zig");
const PLIC = @import("plic.zig");
const std = @import("std");

const UART = @This();

rbr: ?u8, // received byte value
thr: ?u8, // transmit byte value
ier: struct { // interrupt enable register
    rx_avail: bool, // interrupt on byte available to read
    tx_avail: bool, // interrupt on byte available to transmit
},
last_interrupt_cause: ?enum {
    rx_avail, // interrupt caused by byte available to read
    tx_avail, // interrupt caused by byte available to transmit
},
// fcr not implemented (does not exist)
lcr: struct {
    dl_enable: bool,
},
// mcr, msr not implemented (read-only 0)
// scr not implemented (does not exist)
// dll, dlm not implemented, but we honour the dll/dlm enable bit

interrupt_target: *PLIC,
const interrupt_num = 1;

const reg_rbr_thr = 0x0;
const reg_ier = 0x1;
const reg_iir_fcr = 0x2;
const reg_lcr = 0x3;
const reg_mcr = 0x4;
const reg_lsr = 0x5;
const reg_msr = 0x6;

pub const mmio_len = 0x8;

pub fn mmio_reg_read(uart: *UART, comptime T: type, reg_addr: u64) !T {
    if (comptime T != u8) return Exception.LoadAccessFault;
    switch (reg_addr) {
        reg_rbr_thr => {
            if (uart.lcr.dl_enable) return 0;
            // read any received byte, clear rx bit in interrupt cause
            defer uart.rbr = null;
            defer { // if the last interrupt cause was received data being available, reading clears it
                if (uart.last_interrupt_cause) |cause| {
                    if (cause == .rx_avail) uart.last_interrupt_cause = null;
                }
            }
            return if (uart.rbr) |byte| byte else 0;
        },
        reg_ier => { // read ier
            if (uart.lcr.dl_enable) return 0;
            return set_bit(uart.ier.rx_avail, 0) | set_bit(uart.ier.tx_avail, 1);
        },
        reg_iir_fcr => { // read iir
            if (uart.last_interrupt_cause == null) return 0b1;
            defer { // if the last interrupt cause was transmission being available, reading clears it
                if (uart.last_interrupt_cause.? == .tx_avail) uart.last_interrupt_cause = null;
            }
            return switch (uart.last_interrupt_cause.?) {
                .tx_avail => 0b010,
                .rx_avail => 0b100,
            };
        },
        reg_lcr => { // read lcr
            return 0b11 | set_bit(uart.lcr.dl_enable, 7);
        },
        reg_mcr => return 0, // not implemented
        reg_lsr => { // available data sets bit 0, transmission available sets bits 5 and 6
            return set_bit(uart.rbr != null, 0) | set_bit(uart.thr == null, 5) | set_bit(uart.thr == null, 6);
        },
        reg_msr => return 0, // not implemented
        else => return Exception.LoadAccessFault, // scratch register not present
    }
}

pub fn mmio_reg_write(uart: *UART, comptime T: type, reg_addr: u64, v: T) !void {
    if (comptime T != u8) return Exception.StoreAccessFault;
    switch (reg_addr) {
        reg_rbr_thr => {
            if (uart.lcr.dl_enable) return; // ignore writes to dll
            uart.thr = v;
        },
        reg_ier => { // write ier
            if (uart.lcr.dl_enable) return; // ignore writes to dlm
            uart.ier.rx_avail = get_bit(v, 0);
            uart.ier.tx_avail = get_bit(v, 1);
        },
        reg_iir_fcr => return, // ignore writes to fcr, not implemented
        reg_lcr => { // write to lcr, only store dll/dlm enable bit
            uart.lcr.dl_enable = get_bit(v, 7);
        },
        reg_mcr => return, // ignore, not implemented
        reg_lsr => return, // ignore, read-only register
        reg_msr => return, // ignore, not implemented
        else => return Exception.StoreAccessFault,
    }
    return;
}

pub fn run(uart: *UART) void {
    // transmit byte if in buffer
    if (uart.thr) |tx| {
        defer uart.thr = null;
        var byte: [1]u8 = .{tx};
        _ = std.posix.write(1, byte[0..1]) catch {};
    }
    // try receiving byte if receive buffer is empty
    // TODO: make this nicer!
    if (uart.rbr == null) {
        var bytes_pending: c_int = 0;
        _ = std.c.ioctl(0, 0x541b, &bytes_pending);
        if (bytes_pending > 0) {
            var rx: [1]u8 = undefined;
            _ = std.posix.read(0, rx[0..1]) catch {};
            uart.rbr = rx[0];
        }
    }
    uart.interrupt_target.assert_interrupt_pending(interrupt_num, false);
    // try to interrupt if were allowed to
    if (uart.ier.tx_avail and uart.thr == null) {
        // interrupt if transmit buffer is empty and tx available interrupt enabled
        uart.interrupt_target.assert_interrupt_pending(interrupt_num, true);
        uart.last_interrupt_cause = .tx_avail;
    }
    if (uart.ier.rx_avail and uart.rbr != null) {
        // interrupt if we received a byte and rx available interrupt enabled
        uart.last_interrupt_cause = .rx_avail;
        uart.interrupt_target.assert_interrupt_pending(interrupt_num, true);
    }
}

pub fn init() UART {
    return UART{
        .interrupt_target = undefined,
        .rbr = null,
        .thr = null,
        .ier = .{
            .rx_avail = false,
            .tx_avail = false,
        },
        .last_interrupt_cause = null,
        .lcr = .{
            .dl_enable = false,
        },
    };
}

inline fn get_bit(v: u8, bit: u3) bool {
    return ((v >> bit) & 0b1) != 0;
}

inline fn set_bit(v: bool, bit: u3) u8 {
    return @as(u8, @intFromBool(v)) << bit;
}
