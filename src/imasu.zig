const Device = @import("device.zig");
const CLINT = @import("devices/clint.zig");
const PLIC = @import("devices/plic.zig");
const UART = @import("devices/uart.zig");
const ROM = @import("devices/rom.zig");
const Syscon = @import("devices/syscon.zig");
const Memory = @import("memory.zig");
const Hart = @import("hart.zig");
const std = @import("std");

const devicetree = @embedFile("devicetree/imasu64.dtb");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const a = gpa.allocator();
    const args = try std.process.argsAlloc(a);
    defer std.process.argsFree(a, args);

    if (args.len != 2) {
        std.process.exit(1);
    }

    // TODO: accept memory size on command line
    const mem_sz = 256 * 1024 * 1024;

    const image = blk: {
        const file = try std.fs.cwd().openFileZ(args[1], .{});
        defer file.close();
        break :blk try file.readToEndAlloc(a, mem_sz);
    };

    // allocate memory for ram and load image into it
    var ram = try a.alloc(u8, mem_sz);
    @memset(ram, 0);
    @memcpy(ram[0..image.len], image);
    // create memory with ram
    var mem = Memory.create(ram);

    // create a hart
    var hart = Hart.create();

    // create CLINT timer device
    var clint = CLINT.create();
    var clint_dev = Device{
        .kind = .{ .clint = &clint },
        .mmio_base = 0x1100_0000,
        .mmio_len = CLINT.mmio_len,
    };

    // create PLIC device
    var plic = PLIC.create();
    var plic_dev = Device{
        .kind = .{ .plic = &plic },
        .mmio_base = 0x0c00_0000,
        .mmio_len = PLIC.mmio_len,
    };

    // create UART device
    var uart = UART.create();
    var uart_dev = Device{
        .kind = .{ .uart = &uart },
        .mmio_base = 0x1000_0000,
        .mmio_len = UART.mmio_len,
    };

    var syscon = Syscon{};
    // create Syscon
    var syscon_dev = Device{
        .kind = .{ .syscon = &syscon },
        .mmio_base = 0x1110_0000,
        .mmio_len = Syscon.mmio_len,
    };

    const dtb_sz = 64 * 1024;
    var dtb: [dtb_sz]u8 = .{0} ** dtb_sz;
    @memcpy(dtb[0..devicetree.len], devicetree);
    // create DTB ROM device with dtb bytes
    var dtb_rom = ROM{ .mem = &dtb };
    var dtb_dev = Device{
        .kind = .{ .rom = &dtb_rom },
        .mmio_base = 0x7000_0000,
        .mmio_len = dtb_sz,
    };

    hart.mem = &mem;
    clint.timer = try std.time.Timer.start();
    hart.csrs.time_csr_timer = &clint;
    clint.interrupt_target = &hart;
    plic.ctx0_interrupt_target = &hart;
    uart.interrupt_target = &plic;

    // list of all mmio devices
    var mmio_dev_list = [_]*Device{
        &clint_dev,
        &plic_dev,
        &uart_dev,
        &dtb_dev,
        &syscon_dev,
    };
    // attach them to main memory
    mem.devices = mmio_dev_list[0..mmio_dev_list.len];

    // set a1 register to start of dtb rom
    hart.x[11] = dtb_dev.mmio_base;

    // standard input setup
    try stdin_nonblocking();
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

// zig fmt: off
fn stdin_nonblocking() !void {
    const flags = try std.posix.fcntl(0, std.c.F.GETFL, 0);
    _ = try std.posix.fcntl(0, std.c.F.SETFL,
        flags | @as(u32, @bitCast(std.c.O{ .NONBLOCK = true })),
    );
}
// zig fmt: on

fn terminal_make_raw() !void {
    var termios = try std.posix.tcgetattr(0);
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
    termios.lflag.ISIG = false;
    termios.lflag.IEXTEN = false;
    termios.cflag.PARENB = false;
    termios.cflag.CSIZE = .CS8;
    try std.posix.tcsetattr(0, .NOW, termios);
}
