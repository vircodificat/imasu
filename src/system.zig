const std = @import("std");
const Hart = @import("hart.zig");
const Disk = @import("devices/virtio_disk.zig");
const CLINT = @import("devices/clint.zig");
const PLIC = @import("devices/plic.zig");
//const ROM = @import("devices/rom.zig");
const Syscon = @import("devices/syscon.zig");
const UART = @import("devices/uart.zig");

const System = @This();

hart: *Hart,
clint: *CLINT,
uart: *UART,
disk: ?*Disk,
allow_ctrl_c: bool,

pub fn run(self: *System) !noreturn {
    // standard input setup
    try terminal_make_raw(self.allow_ctrl_c);
    defer terminal_restore() catch @panic("Could not restore terminal");
    errdefer terminal_restore() catch @panic("Could not restore terminal");

    // spawn the thread that runs the timer
    var clint_thread = try std.Thread.spawn(.{}, CLINT.task, .{self.clint});
    clint_thread.detach();

    // spawn the thread that runs the UART
    var uart_thread = try std.Thread.spawn(.{}, UART.task, .{self.uart});
    uart_thread.detach();

    if (self.disk) |disk| {
        // spawn the thread that runs the VirtIO disk
        var disk_thread = try std.Thread.spawn(.{}, Disk.task, .{disk});
        disk_thread.detach();
    }
    // run the hart on the main thread
    self.hart.task();
}

var saved_termios: std.posix.termios = undefined;

fn terminal_restore() !void {
    try std.posix.tcsetattr(0, .NOW, saved_termios);
}

fn terminal_make_raw(allow_ctrl_c: bool) !void {
    saved_termios = try std.posix.tcgetattr(0);
    var termios = saved_termios;
    termios.iflag.IGNBRK = false;
    termios.iflag.BRKINT = false;
    termios.iflag.PARMRK = false;
    termios.iflag.ISTRIP = false;
    termios.iflag.INLCR = false;
    termios.iflag.IGNCR = false;
    termios.iflag.ICRNL = false;
    termios.iflag.IXON = false;
    termios.oflag.OPOST = false;
    termios.lflag.ECHO = false;
    termios.lflag.ECHONL = false;
    termios.lflag.ICANON = false;
    termios.lflag.IEXTEN = false;
    termios.cflag.PARENB = false;
    termios.cflag.CSIZE = .CS8;
    if (allow_ctrl_c) termios.lflag.ISIG = false;
    try std.posix.tcsetattr(0, .NOW, termios);
}

pub fn poweroff(self: *System) !void {
    _ = self;
    try terminal_restore();
    std.process.exit(0);
}
