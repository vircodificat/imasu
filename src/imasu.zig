const Device = @import("device.zig");
const CLINT = @import("timer.zig");
const PLIC = @import("plic.zig");
const UART = @import("uart.zig");
const ROM = @import("rom.zig");
const Memory = @import("memory.zig");
const Hart = @import("hart.zig");
const std = @import("std");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const a = gpa.allocator();
    const args = try std.process.argsAlloc(a);
    defer std.process.argsFree(a, args);

    if (args.len != 3) {
        std.process.exit(1);
    }

    // TODO: accept memory size on command line
    const mem_sz = 256 * 1024 * 1024;

    const image_bytes = blk: {
        const file = try std.fs.cwd().openFileZ(args[1], .{});
        defer file.close();
        break :blk try file.readToEndAlloc(a, mem_sz);
    };

    const dtb_bytes = blk: {
        const file = try std.fs.cwd().openFileZ(args[2], .{});
        defer file.close();
        break :blk try file.readToEndAlloc(a, 1024 * 64);
    };

    // allocate memory for ram and load image into it
    var ram = try a.alloc(u8, mem_sz);
    @memset(ram, 0);
    @memcpy(ram[0..image_bytes.len], image_bytes);
    // allocate memory for dtb and load dtb into it
    var dtb = try a.alloc(u8, 1024 * 64);
    @memset(dtb, 0);
    @memcpy(dtb[0..dtb_bytes.len], dtb_bytes);

    // create memory with ram
    var mem = Memory.init(ram);
    // create a hart
    var hart = Hart.init();
    // create CLINT timer device
    var clint = CLINT.init();
    var clint_dev = Device{
        .kind = .{ .clint = &clint },
        .mmio_base = 0x1100_0000,
        .mmio_len = CLINT.mmio_len,
    };
    // create PLIC device
    var plic = PLIC.init();
    var plic_dev = Device{
        .kind = .{ .plic = &plic },
        .mmio_base = 0x0c00_0000,
        .mmio_len = PLIC.mmio_len,
    };
    // create UART device
    var uart = UART.init();
    var uart_dev = Device{
        .kind = .{ .uart = &uart },
        .mmio_base = 0x1000_0000,
        .mmio_len = UART.mmio_len,
    };
    // create DTB ROM device with dtb bytes
    var dtb_rom = ROM{ .mem = dtb_bytes };
    var dtb_dev = Device{
        .kind = .{ .rom = &dtb_rom },
        .mmio_base = 0x7000_0000,
        .mmio_len = 0x1_0000,
    };

    hart.mem = &mem;
    clint.timer = try std.time.Timer.start();
    hart.csrs.time_csr_timer = &clint;
    clint.interrupt_target = &hart;
    plic.ctx0_interrupt_target = &hart;
    uart.interrupt_target = &plic;

    // list of all mmio devices
    var mmio_devices_list = [_]*Device{
        &clint_dev,
        &plic_dev,
        &uart_dev,
        &dtb_dev,
    };
    // attach them to main memory
    mem.devices = mmio_devices_list[0..mmio_devices_list.len];

    // set a1 register to start of dtb rom
    hart.x[11] = dtb_dev.mmio_base;

    try terminal_make_raw();

    // main loop
    while (true) {
        // run plic
        plic.run();
        // check for interrupts to the hart
        hart.try_take_interrupt();
        // run hart
        var cycle: usize = 0;
        while (cycle < 1024) : (cycle += 1) {
            hart.step();
        }
        // run timer
        clint.run();
        // run UART
        // TODO: its own timing loop
        uart.run();
    }
}

const c = @cImport({
    @cInclude("stdlib.h");
    @cInclude("fcntl.h");
    @cInclude("termios.h");
});

var orig_termios: c.termios = undefined;

// taken from termios(3), glibc manual pages
fn atexit_restore_term() callconv(.C) void {
    _ = c.tcsetattr(0, c.TCSANOW, &orig_termios);
}

// taken from termios(3), glibc manual pages
fn terminal_make_raw() !void {
    // set stdin to non-blocking
    const flags = try std.posix.fcntl(0, c.F_GETFL, 0);
    _ = try std.posix.fcntl(0, c.F_SETFL, flags | c.O_NONBLOCK);
    // set terminal to raw mode
    _ = c.tcgetattr(0, &orig_termios);
    var termios = orig_termios;
    termios.c_iflag &= ~@as(c_uint, c.IGNBRK | c.BRKINT | c.PARMRK | c.ISTRIP | c.INLCR | c.IGNCR | c.IGNCR | c.ICRNL | c.IXON);
    termios.c_oflag &= ~@as(c_uint, c.OPOST);
    termios.c_lflag &= ~@as(c_uint, c.ECHO | c.ECHONL | c.ICANON | c.ISIG | c.IEXTEN);
    termios.c_cflag &= ~@as(c_uint, c.CSIZE | c.PARENB);
    termios.c_cflag |= c.CS8;
    _ = c.tcsetattr(0, c.TCSANOW, &termios);
    // restore the terminal at program termination
    _ = c.atexit(&atexit_restore_term);
}
